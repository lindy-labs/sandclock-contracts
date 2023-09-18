// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {MainnetAddresses} from "../../base/MainnetAddresses.sol";
import {PriceConverter} from "../../../src/steth/PriceConverter.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";

/**
 * A script for executing "exitAllPositions" function on the scUsdcV2 vault.
 * This results in withdrawing all WETH invested into  leveraged staking (scWETH vault), repaying all WETH debt (using a flashloan if necessary) and withdrawing all USDC collateral to the vault.
 */
contract ExitAllPositionsScUsdcV2 is Script {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // @dev: maxAceeptableLossPercent - the maximum acceptable loss in percent of the current total assets amount

    uint256 public maxAceeptableLossPercent = 0.02e18; // 2%

    /*//////////////////////////////////////////////////////////////*/

    uint256 keeperPrivateKey = uint256(vm.envOr("KEEPER_PRIVATE_KEY", bytes32(0x0)));
    address keeper = keeperPrivateKey != 0 ? vm.addr(keeperPrivateKey) : MainnetAddresses.KEEPER;
    scUSDCv2 public scUsdcV2 = scUSDCv2(MainnetAddresses.SCUSDCV2);
    MorphoAaveV3ScUsdcAdapter public morphoAdapter = MorphoAaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_MORPHO_ADAPTER);
    AaveV2ScUsdcAdapter public aaveV2Adapter = AaveV2ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV2_ADAPTER);
    AaveV3ScUsdcAdapter public aaveV3Adapter = AaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV3_ADAPTER);

    function run() external {
        console2.log("--ExitAllPositions script running--");

        require(scUsdcV2.hasRole(scUsdcV2.KEEPER_ROLE(), address(keeper)), "invalid keeper");

        uint256 totalAssets = scUsdcV2.totalAssets();
        uint256 minEndTotalAssets = totalAssets.mulWadDown(1e18 - maxAceeptableLossPercent);

        _logVaultInfo("state before");

        vm.startBroadcast(keeper);
        scUsdcV2.exitAllPositions(minEndTotalAssets);
        vm.stopBroadcast();

        _logVaultInfo("state after");
        console2.log("--ExitAllPositions script done--");
    }

    function _logVaultInfo(string memory message) internal view {
        console2.log("\t", message);
        console2.log("total assets\t\t", scUsdcV2.totalAssets());
        console2.log("weth profit\t\t", scUsdcV2.getProfit());
        console2.log("float\t\t\t", scUsdcV2.usdcBalance());
        console2.log("total collateral\t", scUsdcV2.totalCollateral());
        console2.log("total debt\t\t", scUsdcV2.totalDebt());
        console2.log("weth invested\t\t", scUsdcV2.wethInvested());
    }
}
