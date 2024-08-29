// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {MainnetAddresses} from "../base/MainnetAddresses.sol";
import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";
import {scWETHv2} from "../../src/steth/scWETHv2.sol";
import {scUSDCv2} from "../../src/steth/scUSDCv2.sol";
import {Swapper} from "../../src/steth/swapper/Swapper.sol";
import {PriceConverter} from "../../src/steth/priceConverter/PriceConverter.sol";
import {UsdcWethPriceConverter} from "../../src/steth/priceConverter/UsdcWethPriceConverter.sol";
import {AaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {UsdcWethSwapper} from "../../src/steth/swapper/UsdcWethSwapper.sol";

contract DeployScript is MainnetDeployBase {
    scWETHv2 scWethV2 = scWETHv2(payable(MainnetAddresses.SCWETHV2));
    UsdcWethSwapper swapper = new UsdcWethSwapper();
    UsdcWethPriceConverter priceConverter = new UsdcWethPriceConverter();

    function run() external returns (scUSDCv2 scUsdcV2) {
        require(address(swapper) != address(0), "invalid address for Swapper contract");
        require(address(priceConverter) != address(0), "invalid address for PriceConverter contract");
        require(address(scWethV2) != address(0), "invalid address for ScWethV2 contract");

        vm.startBroadcast(deployerAddress);

        // deploy vault
        scUsdcV2 = new scUSDCv2(deployerAddress, keeper, scWethV2, priceConverter, swapper);

        // deploy & add adapters
        MorphoAaveV3ScUsdcAdapter morphoAdapter = new MorphoAaveV3ScUsdcAdapter();
        scUsdcV2.addAdapter(morphoAdapter);
        console2.log("scUSDCv2 MorphoAaveV3ScUsdcAdapter:", address(morphoAdapter));

        AaveV2ScUsdcAdapter aaveV2Adapter = new AaveV2ScUsdcAdapter();
        scUsdcV2.addAdapter(aaveV2Adapter);
        console2.log("scUSDCv2 AaveV2Adapter:", address(aaveV2Adapter));

        AaveV3ScUsdcAdapter aaveV3Adapter = new AaveV3ScUsdcAdapter();
        scUsdcV2.addAdapter(aaveV3Adapter);
        console2.log("scUSDCv2 AaveV3Adapter:", address(aaveV3Adapter));

        // initial deposit
        uint256 usdcAmount = _swapWethForUsdc(0.01 ether);
        _deposit(scUsdcV2, usdcAmount); // 0.01 ether worth of USDC

        _transferAdminRoleToMultisig(scUsdcV2, deployerAddress);

        vm.stopBroadcast();
    }
}
