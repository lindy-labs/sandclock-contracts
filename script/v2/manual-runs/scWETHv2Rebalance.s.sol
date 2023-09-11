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
import {Swapper} from "../../../src/steth/Swapper.sol";
import {PriceConverter} from "../../../src/steth/PriceConverter.sol";
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
 * invests underlying float in the vault
 * and at the same time also reinvests profits made till now by the vault
 *
 * WHAT SHOULD THE SCRIPT DO
 * invest float if there is any
 * reinvest profits/ increase back the ltv of the protocol to the target ltv
 * disinvest/ decrease the ltv of any protocol if it has overshoot
 *
 * cmd
 * first run a local anvil node using " anvil -f YOUR_RPC_URL"
 * Then run the script using
 * forge script script/v2/manual-runs/scWETHv2Rebalance.s.sol --rpc-url http://127.0.0.1:8545 --ffi
 */
contract scWETHv2Rebalance is Script, scWETHv2Helper {
    using FixedPointMathLib for uint256;
    using Surl for *;
    using Strings for *;
    using stdJson for string;

    struct RebalanceDataParams {
        IAdapter adapter;
        uint256 amount;
        uint256 flashLoanAmount;
        bool isSupplyBorrow;
    }

    ////////////////////////// BUTTONS ///////////////////////////////
    uint256 public MORPHO_ALLOCATION_PERCENT = 0.4e18;
    uint256 public MORPHO_TARGET_LTV = 0.8e18;

    uint256 public COMPOUNDV3_ALLOCATION_PERCENT = 0.6e18;
    uint256 public COMPOUNDV3_TARGET_LTV = 0.8e18;

    uint256 public AAVEV3_ALLOCATION_PERCENT = 0;
    uint256 public AAVEV3_TARGET_LTV = 0.8e18;

    // if the ltv overshoots the target ltv by this threshold, disinvest
    uint256 public disinvestThreshold = 0.005e18; // 0.5 %

    // be it weth gained from profits or float amount lying in the vault
    // the contract rebalance method won't be called if the minimum amount to invest is less than this threshold
    uint256 public minimumInvestAmount = 0.1 ether;
    ///////////////////////////////////////////////////////////////////////

    uint256 keeperPrivateKey = uint256(vm.envOr("KEEPER_PRIVATE_KEY", bytes32(0x00)));

    WETH weth = WETH(payable(C.WETH));

    IAdapter public morphoAdapter = IAdapter(MA.SCWETHV2_MORPHO_ADAPTER);
    IAdapter public compoundV3Adapter = IAdapter(MA.SCWETHV2_COMPOUND_ADAPTER);
    IAdapter public aaveV3Adapter = IAdapter(MA.SCWETHV2_AAVEV3_ADAPTER);

    mapping(IAdapter => uint256) public targetLtv;

    RebalanceDataParams[] rebalanceDataParams;
    bytes[] private callDataStorage;
    mapping(IAdapter => uint256) public adapterAllocationPercent;

    constructor() scWETHv2Helper(scWETHv2(payable(MA.SCWETHV2)), PriceConverter(MA.PRICE_CONVERTER)) {
        _initializeAdapters();
    }

    function run() external {
        address keeper = keeperPrivateKey != 0 ? vm.addr(keeperPrivateKey) : MA.KEEPER;

        vm.startBroadcast(keeper);

        _rebalance();

        // _logs();

        vm.stopBroadcast();
    }

    //////////////////////////////// REBALANCE /////////////////////////////////////////////

    function _initializeAdapters() internal {
        uint256 totalAllocationPercent;

        adapterAllocationPercent[morphoAdapter] = MORPHO_ALLOCATION_PERCENT;
        targetLtv[morphoAdapter] = MORPHO_TARGET_LTV;
        totalAllocationPercent += MORPHO_ALLOCATION_PERCENT;

        adapterAllocationPercent[aaveV3Adapter] = AAVEV3_ALLOCATION_PERCENT;
        targetLtv[aaveV3Adapter] = AAVEV3_TARGET_LTV;
        totalAllocationPercent += AAVEV3_ALLOCATION_PERCENT;

        adapterAllocationPercent[compoundV3Adapter] = COMPOUNDV3_ALLOCATION_PERCENT;
        targetLtv[compoundV3Adapter] = COMPOUNDV3_TARGET_LTV;
        totalAllocationPercent += COMPOUNDV3_ALLOCATION_PERCENT;

        require(totalAllocationPercent == 1e18, "totalAllocationPercent != 100%");
    }

    function _investAmount() internal view returns (uint256 investAmount) {
        uint256 float = weth.balanceOf(address(vault));
        uint256 minimumFloat = vault.minimumFloatAmount();
        // investAmount == 0 just reinvests profits
        investAmount = float > minimumFloat ? float - minimumFloat : 0;
    }

    function _updateRebalanceParams() internal {
        uint256 investAmount = _investAmount();

        IAdapter[3] memory allAdapters = [morphoAdapter, compoundV3Adapter, aaveV3Adapter];

        IAdapter adapter;
        uint256 allocationPercent;
        uint256 amount;
        uint256 flashLoanAmount;
        bool isSupplyBorrow;
        for (uint256 i; i < allAdapters.length; i++) {
            adapter = allAdapters[i];
            allocationPercent = adapterAllocationPercent[adapter];

            if (allocationPercent != 0) {
                amount = investAmount.mulWadDown(allocationPercent);
                // first check if allocation Percent is greater than zero
                (flashLoanAmount, isSupplyBorrow) = _calcRebalanceFlashLoanAmount(adapter, amount);

                rebalanceDataParams.push(RebalanceDataParams(adapter, amount, flashLoanAmount, isSupplyBorrow));
            } else {
                uint256 ltv = getLtv(adapter);
                // even if there is no allocation here, we still want to check if a disinvest is needed in this protocol
                if (ltv > targetLtv[adapter] + disinvestThreshold) {
                    (flashLoanAmount, isSupplyBorrow) = _calcRebalanceFlashLoanAmount(adapter, 0);

                    rebalanceDataParams.push(RebalanceDataParams(adapter, 0, flashLoanAmount, false));
                }
            }
        }
    }

    function _rebalance() internal {
        _updateRebalanceParams();
        (bytes[] memory callData, uint256 totalFlashLoanAmount) = _getRebalanceCallData();

        if (totalFlashLoanAmount > minimumInvestAmount.mulWadDown(getLeverage())) {
            console2.log("---- Running Rebalance ----");
            vault.rebalance(_investAmount(), totalFlashLoanAmount, callData);
        }
    }

    function _getRebalanceCallData() internal returns (bytes[] memory, uint256) {
        uint256 stEthRateTolerance = 0.9995e18;
        uint256 n = rebalanceDataParams.length;

        RebalanceDataParams memory data;

        bytes[] memory temp = new bytes[](n);
        uint256 investFlashLoanAmount;
        uint256 disinvestFlashLoanAmount;

        bool thereIsAtleastOneInvest;
        bool thereIsAtleastOneDisinvest;

        uint256 totalWstEthWithdrawn;

        for (uint256 i; i < n; i++) {
            data = rebalanceDataParams[i];

            if (data.isSupplyBorrow) {
                uint256 supplyAmount =
                    priceConverter.ethToWstEth(data.amount + data.flashLoanAmount).mulWadDown(stEthRateTolerance);

                temp[i] = abi.encodeWithSelector(
                    scWETHv2.supplyAndBorrow.selector, data.adapter.id(), supplyAmount, data.flashLoanAmount
                );

                // print the data in selector in readable format
                // console2.log(
                //     "supplyAndBorrow:, adapter: %s, supplyAmount: %s, borrowAmount: %s",
                //     data.adapter.id(),
                //     supplyAmount,
                //     data.flashLoanAmount
                // );

                thereIsAtleastOneInvest = true;
                investFlashLoanAmount += data.flashLoanAmount;
            } else {
                uint256 withdrawAmount = priceConverter.ethToWstEth(data.flashLoanAmount);

                temp[i] = abi.encodeWithSelector(
                    scWETHv2.repayAndWithdraw.selector, data.adapter.id(), data.flashLoanAmount, withdrawAmount
                );

                // print the data in selector in readable format
                // console2.log(
                //     "repayAndWithdraw:, adapter: %s, repayAmount: %s, withdrawAmount: %s",
                //     data.adapter.id(),
                //     data.flashLoanAmount,
                //     withdrawAmount
                // );

                thereIsAtleastOneDisinvest = true;

                totalWstEthWithdrawn += withdrawAmount;
                disinvestFlashLoanAmount += data.flashLoanAmount;
            }
        }

        // 3 scenarios here
        // only invest (calldata length = number of protocols + 1)
        // invest and disinvest (calldata length = number of protocols + 2)
        // only disinvest (calldata length = number of protocols + 1)

        if (thereIsAtleastOneInvest) {
            // console2.log("setting invest calldata");
            uint256 wethSwapAmount = investFlashLoanAmount + _investAmount();
            bytes memory swapData = getSwapData(wethSwapAmount, C.WETH, C.WSTETH);

            if (swapData.length > 0) {
                callDataStorage.push(
                    abi.encodeWithSelector(
                        BaseV2Vault.zeroExSwap.selector, C.WETH, C.WSTETH, wethSwapAmount, swapData, 0
                    )
                );
            } else {
                callDataStorage.push(abi.encodeWithSelector(scWETHv2.swapWethToWstEth.selector, wethSwapAmount));
            }
        }

        for (uint256 i; i < temp.length; i++) {
            callDataStorage.push(temp[i]);
        }

        if (thereIsAtleastOneDisinvest) {
            uint256 wstEthToWethSlippageTolerance = 0.001e18;
            uint256 swapAmount = totalWstEthWithdrawn.mulWadDown(C.ONE + wstEthToWethSlippageTolerance);

            bytes memory swapData = getSwapData(swapAmount, C.WSTETH, C.WETH);

            // console2.log("setting disinvest calldata");
            if (swapData.length > 0) {
                callDataStorage.push(
                    abi.encodeWithSelector(
                        BaseV2Vault.zeroExSwap.selector,
                        C.WSTETH,
                        C.WETH,
                        swapAmount,
                        swapData,
                        C.ONE - wstEthToWethSlippageTolerance
                    )
                );
            } else {
                callDataStorage.push(
                    abi.encodeWithSelector(
                        scWETHv2.swapWstEthToWeth.selector, type(uint256).max, C.ONE - wstEthToWethSlippageTolerance
                    )
                );
            }
        }

        return (callDataStorage, investFlashLoanAmount + disinvestFlashLoanAmount);
    }

    /// @notice returns the amount to flashloan for an adapter
    /// @dev doesn't matter if the vault has to supply/borrow or repay/withdraw
    /// @dev this supports both scenarios
    function _calcRebalanceFlashLoanAmount(IAdapter _adapter, uint256 _amount)
        internal
        view
        returns (uint256 flashLoanAmount, bool isSupplyBorrow)
    {
        uint256 debt = vault.getDebt(_adapter.id());
        uint256 collateral = getCollateralInWeth(_adapter);

        uint256 target = targetLtv[_adapter].mulWadDown(_amount + collateral);

        isSupplyBorrow = target > debt;

        // calculate the flashloan amount needed
        flashLoanAmount = (isSupplyBorrow ? target - debt : debt - target).divWadDown(C.ONE - targetLtv[_adapter]);
    }

    //////////////////////////////// HELPERS /////////////////////////////////////////////

    function getSwapData(uint256 _amount, address _from, address _to) public virtual returns (bytes memory swapData) {
        string memory url = string(
            abi.encodePacked(
                "https://api.0x.org/swap/v1/quote?buyToken=",
                _to.toHexString(),
                "&sellToken=",
                _from.toHexString(),
                "&sellAmount=",
                _amount.toString()
            )
        );

        string[] memory headers = new string[](1);
        headers[0] = string(abi.encodePacked("0x-api-key: ", vm.envString("ZEROX_API_KEY")));
        (uint256 status, bytes memory data) = url.get(headers);

        if (status != 200) {
            console2.log("----- 0x GET request Failed ---- Using backup swappers -------");
        } else {
            string memory json = string(data);
            swapData = json.readBytes(".data");
        }
    }

    function _logs() internal view {
        uint256 collateralInWeth = priceConverter.wstEthToEth(vault.totalCollateral());
        uint256 debt = vault.totalDebt();
        console2.log("\n Total Collateral %s weth", collateralInWeth);
        console2.log("\n Total Debt %s weth", debt);
        console2.log("\n Invested Amount %s weth", collateralInWeth - debt);
        console2.log("\n Total Assets %s weth", vault.totalAssets());
        console2.log("\n Net Leverage", getLeverage());
        console2.log("\n Net LTV", debt.divWadUp(collateralInWeth));
        console2.log("\n WstEth Balance", ERC20(C.WSTETH).balanceOf(address(this)));
    }
}
