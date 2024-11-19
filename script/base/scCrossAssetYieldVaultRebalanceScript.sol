// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {scCrossAssetYieldVaultBaseScript} from "./scCrossAssetYieldVaultBaseScript.sol";
import {scCrossAssetYieldVault} from "src/steth/scCrossAssetYieldVault.sol";

abstract contract scCrossAssetYieldVaultRebalanceScript is scCrossAssetYieldVaultBaseScript {
    using FixedPointMathLib for uint256;

    error ScriptCannotUseUnsupportedAdapter(uint256 id);

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

    // script state
    AdapterSettings[] adapterSettings;
    RebalanceData[] rebalanceDatas;
    uint256 disinvestAmount = 0;
    bytes[] multicallData;

    uint256 public ltvDiffTolerance = 0.05e18; // 5%
    uint256 public maxProfitSellSlippage = 0.01e18; // 1%

    uint256 minProfitToReinvest = _getMinProfitToReinvest();

    // configuration functions

    function _getMinProfitToReinvest() internal view virtual returns (uint256);

    function _initializeAdapterSettings() internal virtual;

    function _startMessage() internal pure override returns (string memory) {
        return "--Rebalance script running--";
    }

    function _endMessage() internal pure override returns (string memory) {
        return "--Rebalance script done--";
    }

    function _execute() internal override {
        _initializeAdapterSettings();
        _checkAllocationPercentages();

        uint256 minReceivedFromProfitSelling = _sellProfitIfAboveDefinedMin();
        uint256 minAssetBalance = minReceivedFromProfitSelling + assetBalance();
        uint256 minFloatRequired = totalAssets().mulWadUp(vault.floatPercentage());
        uint256 missingFloat = minFloatRequired > minAssetBalance ? minFloatRequired - minAssetBalance : 0;
        uint256 investableAmount = minFloatRequired < minAssetBalance ? minAssetBalance - minFloatRequired : 0;

        _createRebalanceMulticallDataForAllAdapters(investableAmount, missingFloat);

        _logVaultInfo("state before rebalance");

        vm.startBroadcast(keeper);
        vault.rebalance(multicallData);
        vm.stopBroadcast();

        _logVaultInfo("state after rebalance");
    }

    function _checkAllocationPercentages() internal view {
        uint256 totalAllocationPercent = 0;
        for (uint256 i = 0; i < adapterSettings.length; i++) {
            AdapterSettings memory settings = adapterSettings[i];
            totalAllocationPercent += settings.investableAmountPercent;
        }

        require(totalAllocationPercent == 1e18, "investable amount percent not 100%");
    }

    function _sellProfitIfAboveDefinedMin() internal returns (uint256) {
        uint256 profit = getProfit();

        if (profit == 0) return 0;

        // account for slippage when swapping target token profits to underlying assets
        uint256 minExpectedProfit = targetTokensPriceInAssets(profit).mulWadDown(1e18 - maxProfitSellSlippage);

        // if profit is too small, don't sell & reinvest
        if (minExpectedProfit < minProfitToReinvest) return 0;

        multicallData.push(abi.encodeWithSelector(scCrossAssetYieldVault.sellProfit.selector, minExpectedProfit));

        return minExpectedProfit;
    }

    function _createAdapterRebalanceData(
        uint256 _adapterId,
        uint256 _targetLtv,
        uint256 _investableAmount,
        uint256 _missingFloat
    ) internal {
        uint256 collateral = getCollateral(_adapterId);
        uint256 debt = getDebt(_adapterId);

        uint256 targetCollateral = collateral + _investableAmount - _missingFloat;
        uint256 targetDebt = assetPriceInTargetTokens(targetCollateral).mulWadDown(_targetLtv);

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

    function _createRebalanceMulticallDataForAllAdapters(uint256 _investableAmount, uint256 _missingFloat) internal {
        for (uint256 i = 0; i < adapterSettings.length; i++) {
            AdapterSettings memory settings = adapterSettings[i];

            if (
                !vault.isSupported(settings.adapterId)
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

    function _createRebalanceMulticallData() internal {
        if (disinvestAmount > 0) {
            multicallData.push(abi.encodeWithSelector(scCrossAssetYieldVault.disinvest.selector, disinvestAmount));
        }

        for (uint256 i = 0; i < rebalanceDatas.length; i++) {
            RebalanceData memory rebalanceData = rebalanceDatas[i];
            if (rebalanceData.supplyAmount > 0) {
                multicallData.push(
                    abi.encodeWithSelector(
                        scCrossAssetYieldVault.supply.selector, rebalanceData.adapterId, rebalanceData.supplyAmount
                    )
                );
            }
            if (rebalanceData.borrowAmount > 0) {
                multicallData.push(
                    abi.encodeWithSelector(
                        scCrossAssetYieldVault.borrow.selector, rebalanceData.adapterId, rebalanceData.borrowAmount
                    )
                );
            }
            if (rebalanceData.repayAmount > 0) {
                multicallData.push(
                    abi.encodeWithSelector(
                        scCrossAssetYieldVault.repay.selector, rebalanceData.adapterId, rebalanceData.repayAmount
                    )
                );
            }
            if (rebalanceData.withdrawAmount > 0) {
                multicallData.push(
                    abi.encodeWithSelector(
                        scCrossAssetYieldVault.withdraw.selector, rebalanceData.adapterId, rebalanceData.withdrawAmount
                    )
                );
            }
        }
    }

    function _logVaultInfo(string memory message) internal view {
        console2.log("\n\t----------------------------");
        console2.log("\t", message);
        console2.log("\t----------------------------");
        console2.log("total assets\t\t", totalAssets());
        console2.log("profit\t\t", getProfit());
        console2.log("float\t\t\t", assetBalance());
        console2.log("total collateral\t", totalCollateral());
        console2.log("total debt\t\t", totalDebt());
        console2.log("invested\t\t", targetTokensInvested());
        console2.log("\t----------------------------");
    }

    function _logScriptParams() internal view virtual override {
        super._logScriptParams();
        console2.log("ltv diff tolerance\t", ltvDiffTolerance);
        console2.log("min profit\t\t", minProfitToReinvest);
        console2.log("max slippage\t\t", maxProfitSellSlippage);
    }
}
