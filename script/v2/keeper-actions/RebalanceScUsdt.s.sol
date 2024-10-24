// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {MainnetAddresses} from "../../base/MainnetAddresses.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";
import {scCrossAssetYieldVault} from "../../../src/steth/scCrossAssetYieldVault.sol";
import {scCrossAssetYieldVaultRebalanceScript} from "../../base/scCrossAssetYieldVaultRebalanceScript.sol";

/**
 * A script for executing rebalance functionality for...
 */
contract RebalanceScUsdt is scCrossAssetYieldVaultRebalanceScript {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // TODO: update comments

    // @dev The following parameters are used to configure the rebalance script.
    // ltvDiffTolerance - the maximum difference between the target ltv and the actual ltv that is allowed for any adapter
    // minUsdcProfitToReinvest - the minimum amount of weth profit (converted to USDC) that needs to be made for reinvesting to make sense (ie gas costs < profit made)
    // maxProfitSellSlippage - the maximum amount of slippage allowed when selling weth profit for usdc
    // investable amount percent - the percentage of the available funds that can be invested for a specific adapter (all have to sum up to 100% or 1e18)
    // target ltv - the target loan to value ratio for a specific adapter. Set to 0 for unused or unsupported adapters!

    function _getMinProfitToReinvest() internal pure override returns (uint256) {
        return 100e6; // 100 USDT
    }

    function _getVaultAddress() internal virtual override returns (scCrossAssetYieldVault) {
        return scCrossAssetYieldVault(vm.envOr("SC_USDC_V2", MainnetAddresses.SCUSDT));
    }

    uint256 public aaveV3InvestableAmountPercent = 1e18; // 100%
    uint256 public aaveV3TargetLtv = 0.65e18; // 65%

    /*//////////////////////////////////////////////////////////////*/

    function _initializeAdapterSettings() internal override {
        adapterSettings.push(
            AdapterSettings({
                adapterId: 1, // TODO: IAdapter(MainnetAddresses.SCUSDT_AAVEV3_ADAPTER).id(),
                investableAmountPercent: aaveV3InvestableAmountPercent,
                targetLtv: aaveV3TargetLtv
            })
        );
    }

    function _logScriptParams() internal view override {
        super._logScriptParams();
        console2.log("aave v3 invest pct\t", aaveV3InvestableAmountPercent);
        console2.log("aave v3 target ltv\t", aaveV3TargetLtv);
    }
}