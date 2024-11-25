// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {MainnetAddresses} from "../../base/MainnetAddresses.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {scCrossAssetYieldVault} from "../../../src/steth/scCrossAssetYieldVault.sol";
import {scCrossAssetYieldVaultReallocateScript} from "../../base/scCrossAssetYieldVaultReallocateScript.sol";

/**
 * A script for executing reallocate functionality for scUsdcV2 vaults.
 */
contract ReallocateScUsdcV2 is scCrossAssetYieldVaultReallocateScript {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// @dev The following parameters are used to configure the reallocate script. The goal is to move funds from one lending protocol to another without touching the invested WETH.
    // NOTE: supply and withdraw amounts have to sum up to 0, same for borrow and repay amounts or else the script will revert
    // use adapter - whether or not to use a specific adapter
    // allocationPercent - the percentage of the total assets used as collateral to be allocated to the protocol adapter

    bool public useMorpho = true;
    uint256 public morphoAllocationPercent = 0;

    bool public useAaveV2 = true;
    uint256 aaveV2AllocationPercent = 0;

    bool public useAaveV3 = false;
    uint256 public aaveV3AllocationPercent = 0;

    /*//////////////////////////////////////////////////////////////*/

    MorphoAaveV3ScUsdcAdapter public morphoAdapter = MorphoAaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_MORPHO_ADAPTER);
    AaveV2ScUsdcAdapter public aaveV2Adapter = AaveV2ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV2_ADAPTER);
    AaveV3ScUsdcAdapter public aaveV3Adapter = AaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV3_ADAPTER);

    function _getVaultAddress() internal override returns (scCrossAssetYieldVault) {
        return scCrossAssetYieldVault(vm.envOr("SC_USDC_V2", MainnetAddresses.SCUSDCV2));
    }

    function _initReallocateData() internal override {
        if (useMorpho) {
            if (!vault.isSupported(morphoAdapter.id())) revert("morpho adapter not supported");

            _createReallocateData(morphoAdapter.id(), morphoAllocationPercent);
        }

        if (useAaveV2) {
            if (!vault.isSupported(aaveV2Adapter.id())) revert("aave v2 adapter not supported");

            _createReallocateData(aaveV2Adapter.id(), aaveV2AllocationPercent);
        }

        if (useAaveV3) {
            if (!vault.isSupported(aaveV3Adapter.id())) revert("aave v3 adapter not supported");

            _createReallocateData(aaveV3Adapter.id(), aaveV3AllocationPercent);
        }
    }

    function _logPositions(string memory message) internal view override {
        console2.log("\n\t----------------------------");
        console2.log(string.concat("\t\t", message));
        console2.log("\t----------------------------");

        console2.log("moprho collateral\t", morphoAdapter.getCollateral(address(vault)));
        console2.log("moprho debt\t\t", morphoAdapter.getDebt(address(vault)));

        console2.log("aave v2 collateral\t", aaveV2Adapter.getCollateral(address(vault)));
        console2.log("aave v2 debt\t\t", aaveV2Adapter.getDebt(address(vault)));

        console2.log("aave v3 collateral\t", aaveV3Adapter.getCollateral(address(vault)));
        console2.log("aave v3 debt\t\t", aaveV3Adapter.getDebt(address(vault)));
        console2.log("\t----------------------------");
    }

    function _logScriptParams() internal view override {
        super._logScriptParams();
        console2.log("flash loan fee pct\t", flashloanFeePercent);
        console2.log("use morpho\t\t", useMorpho);
        console2.log("morpho allocation pct\t", morphoAllocationPercent);
        console2.log("use aave v2\t\t", useAaveV2);
        console2.log("aave v2 allocation pct", aaveV2AllocationPercent);
        console2.log("use aave v3\t\t", useAaveV3);
        console2.log("aave v3 allocation pct", aaveV3AllocationPercent);
    }
}
