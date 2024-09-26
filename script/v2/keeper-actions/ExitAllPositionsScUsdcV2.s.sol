// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {scCrossAssetYieldVaultBaseScript} from "../../base/scCrossAssetYieldVaultBaseScript.sol";
import {MainnetAddresses} from "../../base/MainnetAddresses.sol";
import {PriceConverter} from "../../../src/steth/priceConverter/PriceConverter.sol";
import {scCrossAssetYieldVault} from "../../../src/steth/scCrossAssetYieldVault.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {scWETHv2} from "../../../src/steth/scWETHv2.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";

/**
 * A script for executing "exitAllPositions" function on the scUsdcV2 vault.
 * This results in withdrawing all WETH invested into  leveraged staking (scWETH vault), repaying all WETH debt (using a flashloan if necessary) and withdrawing all USDC collateral to the vault.
 */
contract ExitAllPositionsScUsdcV2 is scCrossAssetYieldVaultBaseScript {
    using Address for address;
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // @dev: maxAceeptableLossPercent - the maximum acceptable loss in percent of the current total assets amount

    uint256 public maxAceeptableLossPercent = 0.02e18; // 2%

    /*//////////////////////////////////////////////////////////////*/

    function run() external {
        console2.log("--Exit all positions ScUsdcV2 script running--");

        require(vault.hasRole(vault.KEEPER_ROLE(), address(keeper)), "invalid keeper");

        _logScriptParams();

        uint256 totalAssets = vault.totalAssets();
        uint256 minEndTotalAssets = totalAssets.mulWadDown(1e18 - maxAceeptableLossPercent);

        _logVaultInfo("state before");

        vm.startBroadcast(keeper);
        vault.exitAllPositions(minEndTotalAssets);
        vm.stopBroadcast();

        _logVaultInfo("state after");
        console2.log("--Exit all positions ScUsdcV2 script done--");
    }

    function getVault() internal override returns (scCrossAssetYieldVault) {
        return scCrossAssetYieldVault(vm.envOr("SC_USDC_V2", MainnetAddresses.SCUSDCV2));
    }

    function _logScriptParams() internal view override {
        super._logScriptParams();
        console2.log("maxAceeptableLossPercent\t", maxAceeptableLossPercent);
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
