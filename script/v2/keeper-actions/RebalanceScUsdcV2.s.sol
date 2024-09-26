// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {scCrossAssetYieldVaultBaseScript} from "../../base/scCrossAssetYieldVaultBaseScript.sol";
import {MainnetAddresses} from "../../base/MainnetAddresses.sol";
import {PriceConverter} from "../../../src/steth/priceConverter/PriceConverter.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";
import {scCrossAssetYieldVault} from "../../../src/steth/scCrossAssetYieldVault.sol";

/**
 * A script for executing rebalance functionality for scUsdcV2 vaults.
 */
contract RebalanceScUsdcV2 is scCrossAssetYieldVaultBaseScript {
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

    MorphoAaveV3ScUsdcAdapter public morphoAdapter = MorphoAaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_MORPHO_ADAPTER);
    AaveV2ScUsdcAdapter public aaveV2Adapter = AaveV2ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV2_ADAPTER);
    AaveV3ScUsdcAdapter public aaveV3Adapter = AaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV3_ADAPTER);

    function run() external {
        console2.log("--RebalanceScUsdcV2 script running--");

        require(vault.hasRole(vault.KEEPER_ROLE(), address(keeper)), "invalid keeper");

        _logScriptParams();

        _initializeAdapterSettings();

        require(
            morphoInvestableAmountPercent + aaveV2InvestableAmountPercent + aaveV3InvestableAmountPercent == 1e18,
            "investable amount percent not 100%"
        );

        uint256 minUsdcFromProfitSelling = _sellWethProfitIfAboveDefinedMin();
        uint256 minUsdcBalance = minUsdcFromProfitSelling + assetBalance();
        uint256 minFloatRequired = vault.totalAssets().mulWadUp(vault.floatPercentage());
        uint256 missingFloat = minFloatRequired > minUsdcBalance ? minFloatRequired - minUsdcBalance : 0;
        uint256 investableAmount = minFloatRequired < minUsdcBalance ? minUsdcBalance - minFloatRequired : 0;

        _createRebalanceMulticallDataForAllAdapters(investableAmount, missingFloat);

        _logVaultInfo("state before rebalance");

        vm.startBroadcast(keeper);
        vault.rebalance(multicallData);
        vm.stopBroadcast();

        _logVaultInfo("state after rebalance");
        console2.log("--RebalanceScUsdcV2 script done--");
    }

    function getVault() internal override returns (scCrossAssetYieldVault) {
        return scCrossAssetYieldVault(vm.envOr("SC_USDC_V2", MainnetAddresses.SCUSDCV2));
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
    }

    function _sellWethProfitIfAboveDefinedMin() internal returns (uint256) {
        uint256 wethProfit = vault.getProfit();
        // account for slippage when selling weth profit for usdc
        uint256 minExpectedUsdcProfit = targetTokensPriceInAssets(wethProfit).mulWadDown(1e18 - maxProfitSellSlippage);

        // if profit is too small, don't sell & reinvest
        if (minExpectedUsdcProfit < minUsdcProfitToReinvest) return 0;

        multicallData.push(abi.encodeWithSelector(scCrossAssetYieldVault.sellProfit.selector, minExpectedUsdcProfit));

        return minExpectedUsdcProfit;
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

    function _createAdapterRebalanceData(
        uint256 _adapterId,
        uint256 _targetLtv,
        uint256 _investableAmount,
        uint256 _missingFloat
    ) internal {
        uint256 collateral = vault.getCollateral(_adapterId);
        uint256 debt = vault.getDebt(_adapterId);

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

    function _logScriptParams() internal view override {
        super._logScriptParams();
        console2.log("ltv diff tolerance\t", ltvDiffTolerance);
        console2.log("min usdc profit\t\t", minUsdcProfitToReinvest);
        console2.log("max profit sell slippage\t", maxProfitSellSlippage);
        console2.log("morpho investable amount percent\t", morphoInvestableAmountPercent);
        console2.log("morpho target ltv\t", morphoTargetLtv);
        console2.log("aave v2 investable amount percent\t", aaveV2InvestableAmountPercent);
        console2.log("aave v2 target ltv\t", aaveV2TargetLtv);
        console2.log("aave v3 investable amount percent\t", aaveV3InvestableAmountPercent);
        console2.log("aave v3 target ltv\t", aaveV3TargetLtv);
    }

    function _logVaultInfo(string memory message) internal view {
        console2.log("\t", message);
        console2.log("total assets\t\t", vault.totalAssets());
        console2.log("weth profit\t\t", vault.getProfit());
        console2.log("float\t\t\t", assetBalance());
        console2.log("total collateral\t", vault.totalCollateral());
        console2.log("total debt\t\t", vault.totalDebt());
        console2.log("weth invested\t\t", targetTokensInvested());
    }
}
