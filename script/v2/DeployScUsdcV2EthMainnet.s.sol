// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";
import {scWETHv2} from "../../src/steth/scWETHv2.sol";
import {scUSDCv2} from "../../src/steth/scUSDCv2.sol";
import {Swapper} from "../../src/steth/Swapper.sol";
import {PriceConverter} from "../../src/steth/PriceConverter.sol";
import {AaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";

contract DeployScript is MainnetDeployBase {
    Swapper swapper = Swapper(vm.envAddress("SWAPPER"));
    PriceConverter priceConverter = PriceConverter(vm.envAddress("PRICE_CONVERTER"));
    scWETHv2 scWethV2 = scWETHv2(payable(vm.envAddress("SC_WETH_V2")));

    function run() external returns (scUSDCv2 scUsdcV2) {
        require(address(swapper) != address(0), "invalid address for Swapper contract");
        require(address(priceConverter) != address(0), "invalid address for PriceConverter contract");
        require(address(scWethV2) != address(0), "invalid address for ScWethV2 contract");

        vm.startBroadcast(deployerAddress);

        // deploy vault
        scUsdcV2 = new scUSDCv2(deployerAddress, keeper, scWethV2, priceConverter, swapper);

        // deploy & add adapters
        AaveV3ScUsdcAdapter aaveV3Adapter = new AaveV3ScUsdcAdapter();
        scUsdcV2.addAdapter(aaveV3Adapter);
        console2.log("scUSDCv2 AaveV3Adapter:", address(aaveV3Adapter));

        AaveV2ScUsdcAdapter aaveV2Adapter = new AaveV2ScUsdcAdapter();
        scUsdcV2.addAdapter(aaveV2Adapter);
        console2.log("scUSDCv2 CompoundV3Adapter:", address(aaveV2Adapter));

        // initial deposit
        uint256 usdcAmount = _swapWethForUsdc(0.01 ether);
        _deposit(scUsdcV2, usdcAmount); // 0.01 ether worth of USDC

        _transferAdminRoleToMultisig(scUsdcV2, deployerAddress);

        vm.stopBroadcast();
    }
}
