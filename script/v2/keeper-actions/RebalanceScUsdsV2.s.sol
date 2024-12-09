// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import "forge-std/console2.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {IAdapter} from "src/steth/IAdapter.sol";
import {IRewardsController} from "src/interfaces/aave-v3/IRewardsController.sol";
import {scCrossAssetYieldVault} from "src/steth/scCrossAssetYieldVault.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {scCrossAssetYieldVaultRebalanceScript} from "script/base/scCrossAssetYieldVaultRebalanceScript.sol";

/**
 * A script for executing rebalance functionality for...
 */
contract RebalanceScUsdsV2 is scCrossAssetYieldVaultRebalanceScript {
    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // @dev The following parameters are used to configure the rebalance script.
    // ltvDiffTolerance (scCrossAssetYieldVaultRebalanceScript) - the maximum difference between the target ltv and the actual ltv that is allowed for any adapter
    // minProfitToReinvest - the minimum amount of WETH profit (converted to USDS) that needs to be made for reinvesting to make sense (ie gas costs < profit made)
    // maxProfitSellSlippage (scCrossAssetYieldVaultRebalanceScript) - the maximum amount of slippage allowed when selling WETH profit for USDS
    // aave v3 investable amount percent - the percentage of the available funds that can be invested for a specific adapter (all have to sum up to 100% or 1e18)
    // aave v3 target ltv - the target loan to value ratio for a specific adapter. Set to 0 for unused or unsupported adapters!

    function _getMinProfitToReinvest() internal pure override returns (uint256) {
        return 100e18; // 100 USDS
    }

    function _claimAndHandleRewards() internal override {
        address[] memory assets = new address[](1);
        assets[0] = C.AAVE_V3_AUSDS_TOKEN;
        uint256 claimableAmount = IRewardsController(C.AAVE_V3_REWARDS_CONTROLLER).getUserRewards(
            assets, address(vault), C.AAVE_V3_AUSDS_TOKEN
        );

        if (claimableAmount != 0) vault.claimRewards(IAdapter(MainnetAddresses.SCUSDS_AAVEV3_ADAPTER).id(), "");
    }

    function _getVaultAddress() internal virtual override returns (scCrossAssetYieldVault) {
        return scCrossAssetYieldVault(vm.envOr("SC_USDSV2", MainnetAddresses.SCUSDSV2));
    }

    uint256 public aaveV3InvestableAmountPercent = 1e18; // 100%
    uint256 public aaveV3TargetLtv = 0.65e18; // 65%

    /*//////////////////////////////////////////////////////////////*/

    function _initializeAdapterSettings() internal override {
        adapterSettings.push(
            AdapterSettings({
                adapterId: IAdapter(MainnetAddresses.SCUSDS_AAVEV3_ADAPTER).id(),
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
