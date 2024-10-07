// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Surl} from "surl/Surl.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {Constants as C} from "../../../src/lib/Constants.sol";
import {MainnetAddresses as MA} from "../../base/MainnetAddresses.sol";
import {ISwapRouter} from "../../../src/interfaces/uniswap/ISwapRouter.sol";
import {sc4626} from "../../../src/sc4626.sol";
import {scWETHv2} from "../../../src/steth/scWETHv2.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {Swapper} from "../../../src/steth/swapper/Swapper.sol";
import {PriceConverter} from "../../../src/steth/priceConverter/PriceConverter.sol";
import {AaveV3ScWethAdapter as scWethAaveV3Adapter} from "../../../src/steth/scWethV2-adapters/AaveV3ScWethAdapter.sol";
import {CompoundV3ScWethAdapter as scWethCompoundV3Adapter} from
    "../../../src/steth/scWethV2-adapters/CompoundV3ScWethAdapter.sol";
import {AaveV3ScUsdcAdapter as scUsdcAaveV3Adapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter as scUsdcAaveV2Adapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {MainnetDeployBase} from "../../base/MainnetDeployBase.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";
import {scWETHv2Helper} from "../../../test/helpers/scWETHv2Helper.sol";
import {BaseV2Vault} from "../../../src/steth/BaseV2Vault.sol";

/**
 * @notice This script is used to reallocate funds between different adapters
 * provided the allocation percents, this script will rebalance the funds to achieve the provided
 * allocation percents
 *
 * cmd
 * first run a local anvil node using " anvil -f YOUR_RPC_URL"
 * Then run the script using
 * forge script script/v2/manual-runs/ReallocateScWethV2.s.sol --rpc-url http://127.0.0.1:8545
 */
contract ReallocateScWethV2 is Script, scWETHv2Helper {
    using FixedPointMathLib for uint256;

    ///////////////////////////////// BUTTONS ////////////////////////////////////////

    // 1e18 = 100%
    uint256 morphoExpectedAllocationPercent = 0e18;
    uint256 aaveV3ExpectedAllocationPercent = 0e18;
    uint256 compoundExpectedAllocationPercent = 0e18;

    //////////////////////////////////////////////////////////////////////////////////

    mapping(IAdapter => uint256) public expectedAllocationPercent;

    uint256 keeperPrivateKey = uint256(vm.envOr("KEEPER_PRIVATE_KEY", bytes32(0x00)));
    address keeper = keeperPrivateKey != 0 ? vm.addr(keeperPrivateKey) : MA.KEEPER;

    WETH weth = WETH(payable(C.WETH));

    IAdapter public morphoAdapter = IAdapter(MA.SCWETHV2_MORPHO_ADAPTER);
    IAdapter public compoundV3Adapter = IAdapter(MA.SCWETHV2_COMPOUND_ADAPTER);
    IAdapter public aaveV3Adapter = IAdapter(MA.SCWETHV2_AAVEV3_ADAPTER);

    struct ReallocateData {
        uint256 adapterId;
        uint256 supplyAmount;
        uint256 borrowAmount;
        uint256 withdrawAmount;
        uint256 repayAmount;
    }

    ReallocateData[] public reallocateData;
    bytes[] private multiCallData;
    uint256 flashLoanAmount;

    constructor() scWETHv2Helper(scWETHv2(payable(MA.SCWETHV2)), PriceConverter(MA.PRICE_CONVERTER)) {
        expectedAllocationPercent[morphoAdapter] = morphoExpectedAllocationPercent;
        expectedAllocationPercent[compoundV3Adapter] = compoundExpectedAllocationPercent;
        expectedAllocationPercent[aaveV3Adapter] = aaveV3ExpectedAllocationPercent;
    }

    function run() public {
        _initReallocateData();
        _createMultiCallData();

        vm.startBroadcast(keeper);

        console2.log("start execution");

        vault.rebalance(0, flashLoanAmount, multiCallData);

        vm.stopBroadcast();
    }

    function _createMultiCallData() internal {
        for (uint256 i; i < reallocateData.length; i++) {
            ReallocateData memory data = reallocateData[i];

            if (data.withdrawAmount > 0) {
                flashLoanAmount += data.repayAmount;

                multiCallData.push(
                    abi.encodeWithSelector(
                        scWETHv2.repayAndWithdraw.selector, data.adapterId, data.repayAmount, data.withdrawAmount
                    )
                );
            }
        }

        for (uint256 i; i < reallocateData.length; i++) {
            ReallocateData memory data = reallocateData[i];

            if (data.supplyAmount > 0) {
                multiCallData.push(
                    abi.encodeWithSelector(
                        scWETHv2.supplyAndBorrow.selector, data.adapterId, data.supplyAmount, data.borrowAmount
                    )
                );
            }
        }
    }

    function _initReallocateData() internal {
        uint256 totalAllocationPercent;
        IAdapter[3] memory allAdapters = [morphoAdapter, compoundV3Adapter, aaveV3Adapter];

        for (uint256 i; i < allAdapters.length; i++) {
            ReallocateData memory data;
            IAdapter adapter = allAdapters[i];
            uint256 id = adapter.id();

            if (!vault.isSupported(id)) revert("adapter not supported");

            data.adapterId = id;

            uint256 allocation = expectedAllocationPercent[adapter];

            uint256 currentCollateral = vault.getCollateral(id);
            uint256 expectedCollateral = vault.totalCollateral().mulWadDown(allocation);

            uint256 currentDebt = vault.getDebt(id);
            uint256 expectedDebt = vault.totalDebt().mulWadDown(allocation);

            if (currentCollateral > expectedCollateral) {
                data.withdrawAmount = currentCollateral - expectedCollateral;
                data.repayAmount = currentDebt - expectedDebt;
            } else if (currentCollateral < expectedCollateral) {
                data.supplyAmount = expectedCollateral - currentCollateral;
                data.borrowAmount = expectedDebt - currentDebt;
            }

            reallocateData.push(data);
            totalAllocationPercent += allocation;
        }

        require(totalAllocationPercent == 1e18, "total allocation percent not 100%");
    }
}
