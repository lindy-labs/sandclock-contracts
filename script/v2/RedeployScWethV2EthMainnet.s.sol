// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {MainnetAddresses} from "../base/MainnetAddresses.sol";
import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";
import {scWETHv2} from "../../src/steth/scWETHv2.sol";
import {Swapper} from "../../src/steth/swapper/Swapper.sol";
import {PriceConverter} from "../../src/steth/priceConverter/PriceConverter.sol";
import {AaveV3ScWethAdapter} from "../../src/steth/scWethV2-adapters/AaveV3ScWethAdapter.sol";
import {CompoundV3ScWethAdapter} from "../../src/steth/scWethV2-adapters/CompoundV3ScWethAdapter.sol";
import {MorphoAaveV3ScWethAdapter} from "../../src/steth/scWethV2-adapters/MorphoAaveV3ScWethAdapter.sol";

contract RedeployScript is MainnetDeployBase {
    Swapper swapper = Swapper(MainnetAddresses.SWAPPER);
    PriceConverter priceConverter = PriceConverter(MainnetAddresses.PRICE_CONVERTER);
    MorphoAaveV3ScWethAdapter morphoAdapter = MorphoAaveV3ScWethAdapter(MainnetAddresses.SCWETHV2_MORPHO_ADAPTER);
    CompoundV3ScWethAdapter compoundV3Adapter = CompoundV3ScWethAdapter(MainnetAddresses.SCWETHV2_COMPOUND_ADAPTER);
    AaveV3ScWethAdapter aaveV3Adapter = AaveV3ScWethAdapter(MainnetAddresses.SCWETHV2_AAVEV3_ADAPTER);

    function run() external returns (scWETHv2 scWethV2) {
        vm.startBroadcast(deployerAddress);

        // deploy vault
        scWethV2 = new scWETHv2(deployerAddress, keeper, weth, swapper, priceConverter);

        // add adapters
        if (address(morphoAdapter) != address(0)) {
            scWethV2.addAdapter(morphoAdapter);
            console2.log("added MorphoAaveV3ScWethAdapter:", address(morphoAdapter));
        }

        if (address(compoundV3Adapter) != address(0)) {
            scWethV2.addAdapter(compoundV3Adapter);
            console2.log("added CompoundV3ScWethAdapter:", address(compoundV3Adapter));
        }

        if (address(aaveV3Adapter) != address(0)) {
            scWethV2.addAdapter(aaveV3Adapter);
            console2.log("added AaveV3ScWethAdapter:", address(aaveV3Adapter));
        }

        // initial deposit
        weth.deposit{value: 0.01 ether}(); // wrap 0.01 ETH into WETH
        _deposit(scWethV2, 0.01 ether); // 0.01 WETH

        _setTreasury(scWethV2, MainnetAddresses.TREASURY);

        _transferAdminRoleToMultisig(scWethV2, deployerAddress);

        vm.stopBroadcast();
    }
}
