// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";
import {scWETHv2} from "../../src/steth/scWETHv2.sol";
import {Swapper} from "../../src/steth/Swapper.sol";
import {PriceConverter} from "../../src/steth/PriceConverter.sol";
import {MorphoAaveV3ScWethAdapter} from "../../src/steth/scWethV2-adapters/MorphoAaveV3ScWethAdapter.sol";
import {CompoundV3ScWethAdapter} from "../../src/steth/scWethV2-adapters/CompoundV3ScWethAdapter.sol";

contract DeployScript is MainnetDeployBase {
    Swapper swapper = Swapper(vm.envAddress("SWAPPER"));
    PriceConverter priceConverter = PriceConverter(vm.envAddress("PRICE_CONVERTER"));

    function run() external returns (scWETHv2 scWethV2) {
        require(address(swapper) != address(0), "invalid address for Swapper contract");
        require(address(priceConverter) != address(0), "invalid address for PriceConverter contract");

        vm.startBroadcast(deployerAddress);

        // deploy vault
        scWethV2 = new scWETHv2(deployerAddress, keeper, weth, swapper, priceConverter);

        // deploy & add adapters
        MorphoAaveV3ScWethAdapter morphoAdapter = new MorphoAaveV3ScWethAdapter();
        scWethV2.addAdapter(morphoAdapter);
        console2.log("scWethV2 MorphoAdapter:", address(morphoAdapter));

        CompoundV3ScWethAdapter compoundV3Adapter = new CompoundV3ScWethAdapter();
        scWethV2.addAdapter(compoundV3Adapter);
        console2.log("scWETHV2 CompoundV3Adapter:", address(compoundV3Adapter));

        // initial deposit
        weth.deposit{value: 0.01 ether}(); // wrap 0.01 ETH into WETH
        _deposit(scWethV2, 0.01 ether); // 0.01 WETH

        _transferAdminRoleToMultisig(scWethV2, deployerAddress);

        vm.stopBroadcast();
    }
}
