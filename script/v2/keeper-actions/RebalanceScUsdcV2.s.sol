// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import "forge-std/console2.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {MainnetAddresses} from "../../base/MainnetAddresses.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {scCrossAssetYieldVault} from "../../../src/steth/scCrossAssetYieldVault.sol";
import {scCrossAssetYieldVaultRebalanceScript} from "../../base/scCrossAssetYieldVaultRebalanceScript.sol";

/**
 * A script for executing rebalance functionality for...
 */
contract RebalanceScUsdcV2 is scCrossAssetYieldVaultRebalanceScript {
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

    function _getMinProfitToReinvest() internal pure override returns (uint256) {
        return 100e6; // 100 USDC
    }

    function _getVaultAddress() internal override returns (scCrossAssetYieldVault) {
        return scCrossAssetYieldVault(vm.envOr("SC_USDC_V2", MainnetAddresses.SCUSDCV2));
    }

    uint256 public morphoInvestableAmountPercent = 1e18; // 100%
    uint256 public morphoTargetLtv = 0.65e18; // 65%

    uint256 public aaveV2InvestableAmountPercent = 0e18; // 0%
    uint256 public aaveV2TargetLtv = 0.65e18; // 65%

    uint256 public aaveV3InvestableAmountPercent = 0e18; // 0%
    uint256 public aaveV3TargetLtv = 0.0e18;

    /*//////////////////////////////////////////////////////////////*/

    MorphoAaveV3ScUsdcAdapter public morphoAdapter = MorphoAaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_MORPHO_ADAPTER);
    AaveV2ScUsdcAdapter public aaveV2Adapter = AaveV2ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV2_ADAPTER);
    AaveV3ScUsdcAdapter public aaveV3Adapter = AaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV3_ADAPTER);

    function _initializeAdapterSettings() internal override {
        adapterSettings.push(
            AdapterSettings({
                adapterId: IAdapter(MainnetAddresses.SCUSDCV2_MORPHO_ADAPTER).id(),
                investableAmountPercent: morphoInvestableAmountPercent,
                targetLtv: morphoTargetLtv
            })
        );

        adapterSettings.push(
            AdapterSettings({
                adapterId: IAdapter(MainnetAddresses.SCUSDCV2_AAVEV2_ADAPTER).id(),
                investableAmountPercent: aaveV2InvestableAmountPercent,
                targetLtv: aaveV2TargetLtv
            })
        );

        adapterSettings.push(
            AdapterSettings({
                adapterId: IAdapter(MainnetAddresses.SCUSDCV2_AAVEV3_ADAPTER).id(),
                investableAmountPercent: aaveV3InvestableAmountPercent,
                targetLtv: aaveV3TargetLtv
            })
        );
    }

    function _logScriptParams() internal view override {
        super._logScriptParams();
        console2.log("morpho invest pct\t", morphoInvestableAmountPercent);
        console2.log("morpho target ltv\t", morphoTargetLtv);
        console2.log("aave v2 invest pct\t", aaveV2InvestableAmountPercent);
        console2.log("aave v2 target ltv\t", aaveV2TargetLtv);
        console2.log("aave v3 invest pct\t", aaveV3InvestableAmountPercent);
        console2.log("aave v3 target ltv\t", aaveV3TargetLtv);
    }
}
