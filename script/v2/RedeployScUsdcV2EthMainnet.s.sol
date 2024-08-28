// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {MainnetAddresses} from "../base/MainnetAddresses.sol";
import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";
import {scWETHv2} from "../../src/steth/scWETHv2.sol";
import {scUSDCv2} from "../../src/steth/scUSDCv2.sol";
import {Swapper} from "../../src/steth/Swapper.sol";
import {PriceConverter} from "../../src/steth/PriceConverter.sol";
import {UsdcWethPriceConverter} from "../../src/steth/priceConverter/UsdcWethPriceConverter.sol";
import {AaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {UsdcWethSwapper} from "../../src/steth/swapper/UsdcWethSwapper.sol";

contract RedeployScript is MainnetDeployBase {
    // @note: change scWethV2 to the address of the deployed scWethV2 contract
    scWETHv2 scWethV2 = scWETHv2(payable(vm.envOr("SC_WETH_V2", address(0))));

    UsdcWethSwapper swapper = new UsdcWethSwapper(); //TODO: scUSDCSwapper(MainnetAddresses.USDC_WETH_SWAPPER);
    // TODO: add address of scUSDCPriceConverter and not create a new instance
    UsdcWethPriceConverter priceConverter = new UsdcWethPriceConverter();
    MorphoAaveV3ScUsdcAdapter morphoAdapter = MorphoAaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_MORPHO_ADAPTER);
    AaveV2ScUsdcAdapter aaveV2Adapter = AaveV2ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV2_ADAPTER);
    AaveV3ScUsdcAdapter aaveV3Adapter = AaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV3_ADAPTER);

    function run() external returns (scUSDCv2 scUsdcV2) {
        console2.log("--Redeploy ScUsdcV2 script running--");

        require(address(scWethV2) != address(0), "invalid address for ScWethV2 contract");

        _logScriptParams();

        vm.startBroadcast(deployerAddress);

        // deploy vault
        scUsdcV2 = new scUSDCv2(deployerAddress, keeper, scWethV2, priceConverter, swapper);

        // add adapters
        if (address(morphoAdapter) != address(0)) {
            scUsdcV2.addAdapter(morphoAdapter);
            console2.log("morphoAaveV3ScUsdcAdapter added");
        }

        if (address(aaveV2Adapter) != address(0)) {
            scUsdcV2.addAdapter(aaveV2Adapter);
            console2.log("aaveV2ScUsdcAdapter added");
        }

        if (address(aaveV3Adapter) != address(0)) {
            scUsdcV2.addAdapter(aaveV3Adapter);
            console2.log("aaveV3ScUsdcAdapter added");
        }

        // initial deposit
        uint256 usdcAmount = _swapWethForUsdc(0.01 ether);
        _deposit(scUsdcV2, usdcAmount); // 0.01 ether worth of USDC

        _transferAdminRoleToMultisig(scUsdcV2, deployerAddress);

        vm.stopBroadcast();

        console2.log("--Redeploy ScUsdcV2 script done--");
    }

    function _logScriptParams() internal view {
        console2.log("\t script params");
        console2.log("deployer\t\t", address(deployerAddress));
        console2.log("keeper\t\t", address(keeper));
        console2.log("scWethV2\t\t", address(scWethV2));
        console2.log("swapper\t\t", address(swapper));
        console2.log("priceConverter\t", address(priceConverter));
        console2.log("morphoAdapter\t\t", address(morphoAdapter));
        console2.log("aaveV2Adapter\t\t", address(aaveV2Adapter));
        console2.log("aaveV3Adapter\t\t", address(aaveV3Adapter));
    }
}
