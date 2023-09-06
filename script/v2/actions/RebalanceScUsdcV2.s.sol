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
 * A script for executing rebalance functionality for scUsdcV2 vaults.
 */
contract RebalanceScUsdcV2 is Script {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // @dev The following parameters are used to configure the rebalance script.
    // minUsdcProfitToReinvest - the minimum amount of weth profit (converted to USDC) that needs to be made for reinvesting to make sense (ie gas costs < profit made)
    // maxProfitSellSlippage - the maximum amount of slippage allowed when selling weth profit for usdc
    // use adapter - whether or not to use a specific adapter
    // investable amount percent - the percentage of the available funds that can be invested for a specific adapter (all have to sum up to 100% or 1e18)
    // target ltv - the target loan to value ratio for a specific adapter

    uint256 public minUsdcProfitToReinvest = 10e6; // 10 USDC (set to a more realistic value ~100 USDC)
    uint256 public maxProfitSellSlippage = 0.01e18; // 1%

    bool public useMorpho = true;
    uint256 public morphoInvestableAmountPercent = 1e18; // 100%
    uint256 public morphoTargetLtv = 0.7e18; // 70%

    bool public useAaveV2 = true;
    uint256 public aaveV2InvestableAmountPercent = 0e18; // 0%
    uint256 public aaveV2TargetLtv = 0.7e18; // 70%

    bool public useAaveV3 = false;
    uint256 public aaveV3InvestableAmountPercent = 0e18; // 0%
    uint256 public aaveV3TargetLtv = 0.7e18; // 70%

    /*//////////////////////////////////////////////////////////////*/

    uint256 keeperPrivateKey = uint256(vm.envOr("KEEPER_PRIVATE_KEY", bytes32(0x0)));
    address keeper = keeperPrivateKey != 0 ? vm.addr(keeperPrivateKey) : MainnetAddresses.KEEPER;
    scUSDCv2 public scUsdcV2 = scUSDCv2(MainnetAddresses.SCUSDCV2);
    MorphoAaveV3ScUsdcAdapter public morphoAdapter = MorphoAaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_MORPHO_ADAPTER);
    AaveV2ScUsdcAdapter public aaveV2Adapter = AaveV2ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV2_ADAPTER);
    AaveV3ScUsdcAdapter public aaveV3Adapter = AaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV3_ADAPTER);

    struct RebalanceData {
        uint256 adapterId;
        uint256 repayAmount;
        uint256 borrowAmount;
        uint256 supplyAmount;
        uint256 withdrawAmount;
    }

    struct AdapterSettings {
        bool isUsed;
        uint256 investableAmountPercent;
        uint256 targetLtv;
    }

    // script state
    mapping(uint256 => AdapterSettings) adapterSettings;
    RebalanceData[] rebalanceDatas;
    uint256 disinvestAmount = 0;
    bytes[] multicallData;

    function run() external {
        console2.log("--RebalanceScUsdcV2 script running--");

        require(scUsdcV2.hasRole(scUsdcV2.KEEPER_ROLE(), address(keeper)), "invalid keeper");

        _initializeAdapterSettings();

        uint256 minUsdcFromProfitSelling = _sellWethProfitIfAboveDefinedMin();
        uint256 minUsdcBalance = minUsdcFromProfitSelling + scUsdcV2.usdcBalance();
        uint256 minFloatRequired = scUsdcV2.totalAssets().mulWadUp(scUsdcV2.floatPercentage());
        uint256 missingFloat = minFloatRequired > minUsdcBalance ? minFloatRequired - minUsdcBalance : 0;
        uint256 investableAmount = minFloatRequired < minUsdcBalance ? minUsdcBalance - minFloatRequired : 0;

        _createRebalanceMulticallDataForAllAdapters(investableAmount, missingFloat);

        _logVaultInfo("state before state");

        vm.startBroadcast(keeper);
        scUsdcV2.rebalance(multicallData);
        vm.stopBroadcast();

        _logVaultInfo("state after rebalance");
        console2.log("--RebalanceScUsdcV2 script done--");
    }

    function _initializeAdapterSettings() internal {
        uint256 totalInvestableAmountPercent = 0;

        if (useMorpho) {
            totalInvestableAmountPercent += morphoInvestableAmountPercent;

            adapterSettings[morphoAdapter.id()] = AdapterSettings({
                isUsed: useMorpho,
                investableAmountPercent: morphoInvestableAmountPercent,
                targetLtv: morphoTargetLtv
            });
        }

        if (useAaveV2) {
            totalInvestableAmountPercent += aaveV2InvestableAmountPercent;

            adapterSettings[aaveV2Adapter.id()] = AdapterSettings({
                isUsed: useAaveV2,
                investableAmountPercent: aaveV2InvestableAmountPercent,
                targetLtv: aaveV2TargetLtv
            });
        }

        if (useAaveV3) {
            totalInvestableAmountPercent += aaveV3InvestableAmountPercent;

            adapterSettings[aaveV3Adapter.id()] = AdapterSettings({
                isUsed: useAaveV3,
                investableAmountPercent: aaveV3InvestableAmountPercent,
                targetLtv: aaveV3TargetLtv
            });
        }

        require(
            morphoInvestableAmountPercent + aaveV2InvestableAmountPercent + aaveV3InvestableAmountPercent == 1e18,
            "total investable amount percent must be 100%"
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
        // note: update upper limit if more adapters are added since "i" is used as the adapterId
        for (uint256 i = 1; i <= 4; i++) {
            if (!scUsdcV2.isSupported(i)) continue;

            _createAdapterRebalanceData(
                i, // adapterId
                adapterSettings[i].targetLtv,
                _investableAmount.mulWadDown(adapterSettings[i].investableAmountPercent),
                _missingFloat.mulWadDown(adapterSettings[i].investableAmountPercent)
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

            if (targetDebt > debt) rebalanceData.borrowAmount = targetDebt - debt;

            if (targetDebt < debt) {
                uint256 repayAmount = debt - targetDebt;
                rebalanceData.repayAmount = repayAmount;
                disinvestAmount += repayAmount;
            }
        } else {
            if (targetDebt < debt) {
                uint256 repayAmount = debt - targetDebt;
                rebalanceData.repayAmount = repayAmount;
                disinvestAmount += repayAmount;
            }
            if (targetDebt > debt) rebalanceData.borrowAmount = targetDebt - debt;

            // if collateral == targetCollateral, no need to withdraw
            if (targetCollateral != collateral) rebalanceData.withdrawAmount = collateral - targetCollateral;
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
