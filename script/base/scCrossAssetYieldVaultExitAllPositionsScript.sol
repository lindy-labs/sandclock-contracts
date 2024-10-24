// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {scCrossAssetYieldVaultBaseScript} from "./scCrossAssetYieldVaultBaseScript.sol";
import {scCrossAssetYieldVault} from "src/steth/scCrossAssetYieldVault.sol";

/**
 * A script for executing "exitAllPositions" function on the scCrossAssetYieldVault contracts.
 * This results in withdrawing all staked assets from the target vault, repaying all debt (using a flashloan if necessary) and withdrawing all collateral.
 */
abstract contract scCrossAssetYieldVaultExitAllPositionsScript is scCrossAssetYieldVaultBaseScript {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    /// @dev maxAceeptableLossPercent - the maximum acceptable loss in percent of the current total assets amount
    function maxAceeptableLossPercent() public view virtual returns (uint256) {
        return 0.02e18; // 2%
    }

    /*//////////////////////////////////////////////////////////////*/

    function _startMessage() internal pure override returns (string memory) {
        return "--Exit all positions script running--";
    }

    function _endMessage() internal pure override returns (string memory) {
        return "--Exit all positions script done--";
    }

    function _logScriptParams() internal view override {
        super._logScriptParams();
        console2.log("maxAceeptableLossPercent\t", maxAceeptableLossPercent());
    }

    function _execute() internal virtual override {
        uint256 totalAssets = vault.totalAssets();
        uint256 minEndTotalAssets = totalAssets.mulWadDown(1e18 - maxAceeptableLossPercent());

        _logVaultInfo("state before");

        vm.startBroadcast(keeper);
        vault.exitAllPositions(minEndTotalAssets);
        vm.stopBroadcast();

        _logVaultInfo("state after");
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
