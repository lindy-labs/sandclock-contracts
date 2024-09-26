// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {MainnetAddresses} from "./MainnetAddresses.sol";
import {PriceConverter} from "../../src/steth/priceConverter/PriceConverter.sol";
import {scCrossAssetYieldVault} from "../../src/steth/scCrossAssetYieldVault.sol";
import {ISinglePairPriceConverter} from "../../src/steth/priceConverter/ISinglePairPriceConverter.sol";

/**
 * A base script for executing keeper functions on `scCrossAssetYieldVault` contracts.
 */
abstract contract scCrossAssetYieldVaultBaseScript is Script {
    uint256 keeperPrivateKey = uint256(vm.envOr("KEEPER_PRIVATE_KEY", bytes32(0x0)));
    // if keeper private key is not provided, use the default keeper address for running the script tests
    address keeper = keeperPrivateKey != 0 ? vm.addr(keeperPrivateKey) : MainnetAddresses.KEEPER;

    scCrossAssetYieldVault vault = getVault();

    function getVault() internal virtual returns (scCrossAssetYieldVault);

    function _logScriptParams() internal view virtual {
        console2.log("\t script params");
        console2.log("keeper\t\t", address(keeper));
        console2.log("vault\t\t", address(vault));
    }

    function targetTokensInvested() public view returns (uint256) {
        return targetVault().convertToAssets(targetVault().balanceOf(address(vault)));
    }

    function targetVault() public view returns (ERC4626) {
        // try to use the vault to get the target vault for older version of scUSDCv2
        (bool ok, bytes memory result) = address(vault).staticcall(abi.encodeWithSignature("scWETH()"));

        return ok ? ERC4626(abi.decode(result, (address))) : vault.targetVault();
    }

    function assetBalance() public view returns (uint256) {
        return vault.asset().balanceOf(address(vault));
    }

    function assetPriceInTargetTokens(uint256 _assetAmount) public view returns (uint256 targetTokenAmount) {
        // try to use the price converter to get the price for older version of scUSDCv2
        (bool ok, bytes memory result) =
            address(vault.priceConverter()).staticcall(abi.encodeWithSignature("usdcToEth(uint256)", _assetAmount));

        targetTokenAmount = ok
            ? abi.decode(result, (uint256))
            : ISinglePairPriceConverter(address(vault.priceConverter())).assetToTargetToken(_assetAmount);
    }

    function targetTokensPriceInAssets(uint256 _targetTokenAmount) public view returns (uint256 assetAmount) {
        // try to use the price converter to get the price for older version of scUSDCv2
        (bool ok, bytes memory result) = address(vault.priceConverter()).staticcall(
            abi.encodeWithSignature("ethToUsdc(uint256)", _targetTokenAmount)
        );

        assetAmount = ok
            ? abi.decode(result, (uint256))
            : ISinglePairPriceConverter(address(vault.priceConverter())).targetTokenToAsset(_targetTokenAmount);
    }
}
