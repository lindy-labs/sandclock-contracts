// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {ScUsdcV2ScriptBase} from "../../base/ScUsdcV2ScriptBase.sol";
import {MainnetAddresses} from "../../base/MainnetAddresses.sol";
import {PriceConverter} from "../../../src/steth/PriceConverter.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";

/**
 * A script for executing rebalance functionality for scUsdcV2 vaults.
 */
contract RebalanceScUsdcV2 is ScUsdcV2ScriptBase {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // @dev The following parameters are used to configure the rebalance script.
    // ltvDiffTolerance - the maximum difference between the target ltv and the actual ltv that is allowed for any adapter
    // minUsdcProfitToReinvest - the minimum amount of weth profit (converted to USDC) that needs to be made for reinvesting to make sense (ie gas costs < profit made)
    // maxProfitSellSlippage - the maximum amount of slippage allowed when selling weth profit for usdc
    // investable amount percent - the percentage of the available funds that can be invested for a specific adapter (all have to sum up to 100% or 1e18)
    // target ltv - the target loan to value ratio for a specific adapter. Set to 0 for unused or unsupported adapters!

    uint256 public ltvDiffTolerance = 0.05e18; // 5%
    uint256 public minUsdcProfitToReinvest = 100e6; // 100 USDC
    uint256 public maxProfitSellSlippage = 0.01e18; // 1%

    uint256 public morphoInvestableAmountPercent = 1e18; // 100%
    uint256 public morphoTargetLtv = 0.65e18; // 65%

    uint256 public aaveV2InvestableAmountPercent = 0e18; // 0%
    uint256 public aaveV2TargetLtv = 0.65e18; // 65%

    uint256 public aaveV3InvestableAmountPercent = 0e18; // 0%
    uint256 public aaveV3TargetLtv = 0.0e18;

    /*//////////////////////////////////////////////////////////////*/

    struct RebalanceData {
        uint256 adapterId;
        uint256 repayAmount;
        uint256 borrowAmount;
        uint256 supplyAmount;
        uint256 withdrawAmount;
    }

    struct AdapterSettings {
        uint256 adapterId;
        uint256 investableAmountPercent;
        uint256 targetLtv;
    }

    error ScriptCannotUseUnsupportedAdapter(uint256 id);

    // script state
    AdapterSettings[] adapterSettings;
    RebalanceData[] rebalanceDatas;
    uint256 disinvestAmount = 0;
    bytes[] multicallData;

    function run() external {
        console2.log("--RebalanceScUsdcV2 script running--");

        require(scUsdcV2.hasRole(scUsdcV2.KEEPER_ROLE(), address(keeper)), "invalid keeper");

        _logScriptParams();

        _initializeAdapterSettings();

        uint256 minUsdcFromProfitSelling = _sellWethProfitIfAboveDefinedMin();
        uint256 minUsdcBalance = minUsdcFromProfitSelling + scUsdcV2.usdcBalance();
        uint256 minFloatRequired = scUsdcV2.totalAssets().mulWadUp(scUsdcV2.floatPercentage());
        uint256 missingFloat = minFloatRequired > minUsdcBalance ? minFloatRequired - minUsdcBalance : 0;
        uint256 investableAmount = minFloatRequired < minUsdcBalance ? minUsdcBalance - minFloatRequired : 0;

        _createRebalanceMulticallDataForAllAdapters(investableAmount, missingFloat);

        _logVaultInfo("state before rebalance");

        vm.startBroadcast(keeper);
        scUsdcV2.rebalance(multicallData);
        vm.stopBroadcast();

        _logVaultInfo("state after rebalance");
        console2.log("--RebalanceScUsdcV2 script done--");
    }

    function _initializeAdapterSettings() internal {
        adapterSettings.push(
            AdapterSettings({
                adapterId: morphoAdapter.id(),
                investableAmountPercent: morphoInvestableAmountPercent,
                targetLtv: morphoTargetLtv
            })
        );

        adapterSettings.push(
            AdapterSettings({
                adapterId: aaveV2Adapter.id(),
                investableAmountPercent: aaveV2InvestableAmountPercent,
                targetLtv: aaveV2TargetLtv
            })
        );

        adapterSettings.push(
            AdapterSettings({
                adapterId: aaveV3Adapter.id(),
                investableAmountPercent: aaveV3InvestableAmountPercent,
                targetLtv: aaveV3TargetLtv
            })
        );

        require(
            morphoInvestableAmountPercent + aaveV2InvestableAmountPercent + aaveV3InvestableAmountPercent == 1e18,
            "investable amount percent not 100%"
        );
    }

    function _sellWethProfitIfAboveDefinedMin() internal returns (uint256) {
        uint256 wethProfit = scUsdcV2.getProfit();
        // account for slippage when selling weth profit for usdc
        uint256 minExpectedUsdcProfit =
            scUsdcV2.priceConverter().ethToUsdc(wethProfit).mulWadDown(1e18 - maxProfitSellSlippage);

        // if profit is too small, don't sell & reinvest
        if (minExpectedUsdcProfit < minUsdcProfitToReinvest) return 0;

        multicallData.push(abi.encodeWithSelector(scUSDCv2.sellProfit.selector, minExpectedUsdcProfit));

        return minExpectedUsdcProfit;
    }

    function _createRebalanceMulticallDataForAllAdapters(uint256 _investableAmount, uint256 _missingFloat) internal {
        for (uint256 i = 0; i < adapterSettings.length; i++) {
            AdapterSettings memory settings = adapterSettings[i];

            if (
                !scUsdcV2.isSupported(settings.adapterId)
                    && (settings.targetLtv > 0 || settings.investableAmountPercent > 0)
            ) {
                revert ScriptCannotUseUnsupportedAdapter(settings.adapterId);
            }

            _createAdapterRebalanceData(
                settings.adapterId,
                settings.targetLtv,
                _investableAmount.mulWadDown(settings.investableAmountPercent),
                _missingFloat.mulWadDown(settings.investableAmountPercent)
            );
        }

        _createRebalanceMulticallData();
    }

    function _createAdapterRebalanceData(
        uint256 _adapterId,
        uint256 _targetLtv,
        uint256 _investableAmount,
        uint256 _missingFloat
    ) internal {
        uint256 collateral = scUsdcV2.getCollateral(_adapterId);
        uint256 debt = scUsdcV2.getDebt(_adapterId);

        uint256 targetCollateral = collateral + _investableAmount - _missingFloat;
        uint256 targetDebt = scUsdcV2.priceConverter().usdcToEth(targetCollateral).mulWadDown(_targetLtv);

        RebalanceData memory rebalanceData;
        rebalanceData.adapterId = _adapterId;

        if (targetCollateral > collateral) {
            rebalanceData.supplyAmount = targetCollateral - collateral;
        } else if (targetCollateral < collateral) {
            rebalanceData.withdrawAmount = collateral - targetCollateral;
        }

        uint256 debtUpperBound = targetDebt.mulWadUp(1e18 + ltvDiffTolerance);
        uint256 debtLowerBound = targetDebt.mulWadDown(1e18 - ltvDiffTolerance);

        if (debt < debtLowerBound) {
            rebalanceData.borrowAmount = targetDebt - debt;
        } else if (debt > debtUpperBound) {
            uint256 repayAmount = debt - targetDebt;
            rebalanceData.repayAmount = repayAmount;
            disinvestAmount += repayAmount;
        }

        rebalanceDatas.push(rebalanceData);
    }

    function _createRebalanceMulticallData() internal {
        if (disinvestAmount > 0) {
            multicallData.push(abi.encodeWithSelector(scUsdcV2.disinvest.selector, disinvestAmount));
        }

        for (uint256 i = 0; i < rebalanceDatas.length; i++) {
            RebalanceData memory rebalanceData = rebalanceDatas[i];
            if (rebalanceData.supplyAmount > 0) {
                multicallData.push(
                    abi.encodeWithSelector(
                        scUsdcV2.supply.selector, rebalanceData.adapterId, rebalanceData.supplyAmount
                    )
                );
            }
            if (rebalanceData.borrowAmount > 0) {
                multicallData.push(
                    abi.encodeWithSelector(
                        scUsdcV2.borrow.selector, rebalanceData.adapterId, rebalanceData.borrowAmount
                    )
                );
            }
            if (rebalanceData.repayAmount > 0) {
                multicallData.push(
                    abi.encodeWithSelector(scUsdcV2.repay.selector, rebalanceData.adapterId, rebalanceData.repayAmount)
                );
            }
            if (rebalanceData.withdrawAmount > 0) {
                multicallData.push(
                    abi.encodeWithSelector(
                        scUSDCv2.withdraw.selector, rebalanceData.adapterId, rebalanceData.withdrawAmount
                    )
                );
            }
        }
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
