// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {MainnetAddresses} from "../base/MainnetAddresses.sol";
import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";
import {scWETHv2} from "../../src/steth/scWETHv2.sol";
import {scDAI} from "../../src/steth/scDAI.sol";
import {Swapper} from "../../src/steth/Swapper.sol";
import {PriceConverter} from "../../src/steth/PriceConverter.sol";
import {SparkScDaiAdapter} from "../../src/steth/scDai-adapters/SparkScDaiAdapter.sol";
import {IAdapter} from "../../src/steth/IAdapter.sol";

import {CREATE3Script} from "../base/CREATE3Script.sol";

contract DeployScDaiMainnet is MainnetDeployBase {
    scWETHv2 scWethV2 = scWETHv2(payable(0x4c406C068106375724275Cbff028770C544a1333));

    Swapper swapper;
    PriceConverter priceConverter;
    IAdapter sparkAdapter;

    function run() external {
        console2.log("--Deploy scDAI script running--");

        require(address(scWethV2) != address(0), "invalid address for ScWethV2 contract");

        _logScriptParams();

        vm.startBroadcast(deployerAddress);

        swapper = new Swapper();
        priceConverter = new PriceConverter(MainnetAddresses.MULTISIG);
        sparkAdapter = new SparkScDaiAdapter();

        // deploy vault
        scDAI vault = new scDAI(deployerAddress, keeper, scWethV2, priceConverter, swapper);

        vault.addAdapter(sparkAdapter);

        // initial deposit
        // uint256 usdcAmount = _swapWethForUsdc(0.01 ether);
        // _deposit(scUsdcV2, usdcAmount); // 0.01 ether worth of USDC

        _transferAdminRoleToMultisig(vault, deployerAddress);

        vm.stopBroadcast();

        console2.log("--Deploy scDAI script done--");
    }

    function _logScriptParams() internal view {
        console2.log("\t script params");
        console2.log("deployer\t\t", address(deployerAddress));
        console2.log("keeper\t\t", address(keeper));
        console2.log("scWethV2\t\t", address(scWethV2));
        console2.log("swapper\t\t", address(swapper));
        console2.log("priceConverter\t\t", address(priceConverter));
        console2.log("sparkAdapter\t\t", address(sparkAdapter));
    }
}
