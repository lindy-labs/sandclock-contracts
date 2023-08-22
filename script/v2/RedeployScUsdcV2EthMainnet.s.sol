// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {MainnetAddresses} from "../base/MainnetAddresses.sol";
import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";
import {scWETHv2} from "../../src/steth/scWETHv2.sol";
import {scUSDCv2} from "../../src/steth/scUSDCv2.sol";
import {Swapper} from "../../src/steth/Swapper.sol";
import {PriceConverter} from "../../src/steth/PriceConverter.sol";
import {AaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";

contract RedeployScript is MainnetDeployBase {
    // @note: change scWethV2 to the address of the deployed scWethV2 contract
    scWETHv2 scWethV2 = scWETHv2(payable(vm.envAddress("SC_WETH_V2")));

    Swapper swapper = Swapper(MainnetAddresses.SWAPPER);
    PriceConverter priceConverter = PriceConverter(MainnetAddresses.PRICE_CONVERTER);
    MorphoAaveV3ScUsdcAdapter morphoAdapter = MorphoAaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_MORPHO_ADAPTER);
    AaveV2ScUsdcAdapter aaveV2Adapter = AaveV2ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV2_ADAPTER);
    // @note: update after the deployment of the AaveV3ScUsdcAdapter
    AaveV3ScUsdcAdapter aaveV3Adapter = AaveV3ScUsdcAdapter(address(0));

    function run() external returns (scUSDCv2 scUsdcV2) {
        require(address(scWethV2) != address(0), "invalid address for ScWethV2 contract");

        vm.startBroadcast(deployerAddress);

        // deploy vault
        scUsdcV2 = new scUSDCv2(deployerAddress, keeper, scWethV2, priceConverter, swapper);

        // add adapters
        if (address(morphoAdapter) != address(0)) {
            scUsdcV2.addAdapter(morphoAdapter);
            console2.log("added MorphoAaveV3ScUsdcAdapter:", address(morphoAdapter));
        }

        if (address(aaveV2Adapter) != address(0)) {
            scUsdcV2.addAdapter(aaveV2Adapter);
            console2.log("added AaveV2ScUsdcAdapter:", address(aaveV2Adapter));
        }

        if (address(aaveV3Adapter) != address(0)) {
            scUsdcV2.addAdapter(aaveV3Adapter);
            console2.log("added AaveV3ScUsdcAdapter:", address(aaveV3Adapter));
        }

        // initial deposit
        uint256 usdcAmount = _swapWethForUsdc(0.01 ether);
        _deposit(scUsdcV2, usdcAmount); // 0.01 ether worth of USDC

        _transferAdminRoleToMultisig(scUsdcV2, deployerAddress);

        vm.stopBroadcast();
    }
}
