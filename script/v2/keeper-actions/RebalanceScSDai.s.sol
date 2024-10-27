// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {scCrossAssetYieldVault} from "src/steth/scCrossAssetYieldVault.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {scCrossAssetYieldVaultRebalanceScript} from "script/base/scCrossAssetYieldVaultRebalanceScript.sol";

/**
 * A script for executing rebalance functionality for...
 */
contract RebalanceScSDai is scCrossAssetYieldVaultRebalanceScript {
    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // @dev The following parameters are used to configure the rebalance script.
    // ltvDiffTolerance (scCrossAssetYieldVaultRebalanceScript) - the maximum difference between the target ltv and the actual ltv that is allowed for any adapter
    // minProfitToReinvest - the minimum amount of WETH profit (converted to USDT) that needs to be made for reinvesting to make sense (ie gas costs < profit made)
    // maxProfitSellSlippage (scCrossAssetYieldVaultRebalanceScript) - the maximum amount of slippage allowed when selling WETH profit for USDT
    // aave v3 investable amount percent - the percentage of the available funds that can be invested for a specific adapter (all have to sum up to 100% or 1e18)
    // aave v3 target ltv - the target loan to value ratio for a specific adapter. Set to 0 for unused or unsupported adapters!

    function _getMinProfitToReinvest() internal pure override returns (uint256) {
        return 100e18; // 100 sDAI
    }

    function _getVaultAddress() internal virtual override returns (scCrossAssetYieldVault) {
        return scCrossAssetYieldVault(vm.envOr("SC_SDAI", MainnetAddresses.SCSDAI));
    }

    uint256 public sparkInvestableAmountPercent = 1e18; // 100%
    uint256 public sparkTargetLtv = 0.65e18; // 65%

    /*//////////////////////////////////////////////////////////////*/

    function _initializeAdapterSettings() internal override {
        adapterSettings.push(
            AdapterSettings({
                adapterId: 1, // TODO: IAdapter(MainnetAddresses.SCSDAI_SPARK_ADAPTER).id(),
                investableAmountPercent: sparkInvestableAmountPercent,
                targetLtv: sparkTargetLtv
            })
        );
    }

    function _logScriptParams() internal view override {
        super._logScriptParams();
        console2.log("spark invest pct\t", sparkInvestableAmountPercent);
        console2.log("spark target ltv\t", sparkTargetLtv);
    }
}
