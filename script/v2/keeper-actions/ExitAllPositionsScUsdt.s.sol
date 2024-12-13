// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import {scCrossAssetYieldVault} from "src/steth/scCrossAssetYieldVault.sol";
import {scCrossAssetYieldVaultExitAllPositionsScript} from
    "script/base/scCrossAssetYieldVaultExitAllPositionsScript.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";

/**
 * A script for executing "exitAllPositions" function on the scUSDT vault.
 * This results in withdrawing all WETH invested into  leveraged staking (scWETH vault), repaying all WETH debt (using a flashloan if necessary) and withdrawing all USDT collateral to the vault.
 */
contract ExitAllPositionsScUsdt is scCrossAssetYieldVaultExitAllPositionsScript {
    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // maxAceeptableLossPercent - the maximum acceptable loss in percent of the current total assets amount
    // NOTE: override to change the max acceptable loss percent
    // function maxAceeptableLossPercent() public pure override returns (uint256) {
    //     return 0.02e18; // 2%
    // }

    function _getVaultAddress() internal virtual override returns (scCrossAssetYieldVault) {
        return scCrossAssetYieldVault(vm.envOr("SC_USDT", MainnetAddresses.SCUSDT));
    }

    /*//////////////////////////////////////////////////////////////*/
}
