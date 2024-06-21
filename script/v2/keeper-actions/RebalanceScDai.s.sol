// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {Surl} from "surl/Surl.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {Constants as C} from "../../../src/lib/Constants.sol";
import {MainnetAddresses} from "../../base/MainnetAddresses.sol";
import {PriceConverter} from "../../../src/steth/PriceConverter.sol";
import {scSDAI} from "../../../src/steth/scSDAI.sol";
import {SparkScDaiAdapter} from "../../../src/steth/scDai-adapters/SparkScDaiAdapter.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";

/**
 * A script for executing rebalance functionality for scDAI vaults.
 */
contract RebalanceScDAI is Script {
    using FixedPointMathLib for uint256;
    using Surl for *;
    using Strings for *;
    using stdJson for string;

    uint256 keeperPrivateKey = uint256(vm.envOr("KEEPER_PRIVATE_KEY", bytes32(0x0)));
    // if keeper private key is not provided, use the default keeper address for running the script tests
    address keeper = keeperPrivateKey != 0 ? vm.addr(keeperPrivateKey) : MainnetAddresses.KEEPER;

    scSDAI public vault = scSDAI(vm.envOr("SC_SDAI", MainnetAddresses.SCSDAI));

    PriceConverter priceConverter = PriceConverter(vm.envOr("PRICE_CONVERTER", MainnetAddresses.PRICE_CONVERTER));

    SparkScDaiAdapter public sparkAdapter = SparkScDaiAdapter(MainnetAddresses.SCDAI_SPARK_ADAPTER);

    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // @dev The following parameters are used to configure the rebalance script.
    // ltvDiffTolerance - the maximum difference between the target ltv and the actual ltv that is allowed for any adapter
    // minSDaiProfitToReinvest - the minimum amount of weth profit (converted to USDC) that needs to be made for reinvesting to make sense (ie gas costs < profit made)
    // maxProfitSellSlippage - the maximum amount of slippage allowed when selling weth profit for dai
    // investable amount percent - the percentage of the available funds that can be invested for a specific adapter (all have to sum up to 100% or 1e18)
    // target ltv - the target loan to value ratio for a specific adapter. Set to 0 for unused or unsupported adapters!

    uint256 public ltvDiffTolerance = 0.05e18; // 5%
    uint256 public minSDaiProfitToReinvest = 100e18; // 100 SDAI
    uint256 public maxProfitSellSlippage = 0.01e18; // 1%

    uint256 public sparkInvestableAmountPercent = 1e18; // 100%
    uint256 public sparkTargetLtv = 0.65e18;

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
        console2.log("--RebalancescsDAI script running--");

        require(vault.hasRole(vault.KEEPER_ROLE(), address(keeper)), "invalid keeper");

        _logScriptParams();

        _initializeAdapterSettings();

        uint256 minUsdcFromProfitSelling = _sellWethProfitIfAboveDefinedMin();
        uint256 minUsdcBalance = minUsdcFromProfitSelling + vault.sDaiBalance();
        uint256 minFloatRequired = vault.totalAssets().mulWadUp(vault.floatPercentage());
        uint256 missingFloat = minFloatRequired > minUsdcBalance ? minFloatRequired - minUsdcBalance : 0;
        uint256 investableAmount = minFloatRequired < minUsdcBalance ? minUsdcBalance - minFloatRequired : 0;

        _createRebalanceMulticallDataForAllAdapters(investableAmount, missingFloat);

        _logVaultInfo("state before rebalance");

        vm.startBroadcast(keeper);
        vault.rebalance(multicallData);
        vm.stopBroadcast();

        _logVaultInfo("state after rebalance");
        console2.log("--RebalancescsDAI script done--");
    }

    function _initializeAdapterSettings() internal {
        adapterSettings.push(
            AdapterSettings({
                adapterId: sparkAdapter.id(),
                investableAmountPercent: sparkInvestableAmountPercent,
                targetLtv: sparkTargetLtv
            })
        );
    }

    function _sellWethProfitIfAboveDefinedMin() internal returns (uint256) {
        uint256 wethProfit = vault.getProfit();
        // account for slippage when selling weth profit for sDai
        uint256 minExpectedsDaiProfit =
            vault.priceConverter().ethTosDai(wethProfit).mulWadDown(1e18 - maxProfitSellSlippage);

        // if profit is too small, don't sell & reinvest
        if (minExpectedsDaiProfit < minSDaiProfitToReinvest) return 0;

        multicallData.push(abi.encodeWithSelector(scSDAI.sellProfit.selector, minExpectedsDaiProfit));

        return minExpectedsDaiProfit;
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
        uint256 targetDebt = vault.priceConverter().sDaiToEth(targetCollateral).mulWadDown(_targetLtv);

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
            multicallData.push(abi.encodeWithSelector(scSDAI.disinvest.selector, disinvestAmount));
        }

        for (uint256 i = 0; i < rebalanceDatas.length; i++) {
            RebalanceData memory rebalanceData = rebalanceDatas[i];
            if (rebalanceData.supplyAmount > 0) {
                multicallData.push(
                    abi.encodeWithSelector(scSDAI.supply.selector, rebalanceData.adapterId, rebalanceData.supplyAmount)
                );
            }
            if (rebalanceData.borrowAmount > 0) {
                multicallData.push(
                    abi.encodeWithSelector(scSDAI.borrow.selector, rebalanceData.adapterId, rebalanceData.borrowAmount)
                );
            }
            if (rebalanceData.repayAmount > 0) {
                multicallData.push(
                    abi.encodeWithSelector(scSDAI.repay.selector, rebalanceData.adapterId, rebalanceData.repayAmount)
                );
            }
            if (rebalanceData.withdrawAmount > 0) {
                multicallData.push(
                    abi.encodeWithSelector(
                        scSDAI.withdraw.selector, rebalanceData.adapterId, rebalanceData.withdrawAmount
                    )
                );
            }
        }
    }

    function _logScriptParams() internal view {
        console2.log("\t script params");
        console2.log("keeper\t\t", address(keeper));
        console2.log("scSDAI\t\t", address(vault));
        console2.log("ltv diff tolerance\t", ltvDiffTolerance);
        console2.log("min sDai profit\t\t", minSDaiProfitToReinvest);
        console2.log("max profit sell slippage\t", maxProfitSellSlippage);
        console2.log("spark investable amount percent\t", sparkInvestableAmountPercent);
        console2.log("spark target ltv\t", sparkTargetLtv);
    }

    function _logVaultInfo(string memory message) internal view {
        console2.log("\t", message);
        console2.log("total assets\t\t", vault.totalAssets());
        console2.log("weth profit\t\t", vault.getProfit());
        console2.log("float\t\t\t", vault.sDaiBalance());
        console2.log("total collateral\t", vault.totalCollateral());
        console2.log("total debt\t\t", vault.totalDebt());
        console2.log("weth invested\t\t", vault.wethInvested());
    }
}
