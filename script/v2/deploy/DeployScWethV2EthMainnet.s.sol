// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {MainnetDeployBase} from "script/base/MainnetDeployBase.sol";
import {scWETHv2} from "src/steth/scWETHv2.sol";
import {Swapper} from "src/steth/swapper/Swapper.sol";
import {PriceConverter} from "src/steth/priceConverter/PriceConverter.sol";
import {AaveV3ScWethAdapter} from "src/steth/scWethV2-adapters/AaveV3ScWethAdapter.sol";
import {MorphoAaveV3ScWethAdapter} from "src/steth/scWethV2-adapters/MorphoAaveV3ScWethAdapter.sol";
import {CompoundV3ScWethAdapter} from "src/steth/scWethV2-adapters/CompoundV3ScWethAdapter.sol";

contract DeployScript is MainnetDeployBase {
    Swapper swapper = Swapper(MainnetAddresses.SWAPPER);
    PriceConverter priceConverter = PriceConverter(MainnetAddresses.PRICE_CONVERTER);

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

        AaveV3ScWethAdapter aaveV3Adapter = new AaveV3ScWethAdapter();
        scWethV2.addAdapter(aaveV3Adapter);
        console2.log("scWETHV2 AaveV3Adapter:", address(aaveV3Adapter));

        // initial deposit
        weth.deposit{value: 0.01 ether}(); // wrap 0.01 ETH into WETH
        _deposit(scWethV2, 0.01 ether); // 0.01 WETH

        _transferAdminRoleToMultisig(scWethV2);

        _setTreasury(scWethV2, MainnetAddresses.TREASURY);

        vm.stopBroadcast();
    }
}
