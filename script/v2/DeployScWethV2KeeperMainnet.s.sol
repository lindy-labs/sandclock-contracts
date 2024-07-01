// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {MainnetAddresses} from "../base/MainnetAddresses.sol";
import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";
import {scWETHv2} from "../../src/steth/scWETHv2.sol";
import {scWETHv2Keeper} from "../../src/steth/scWETHv2Keeper.sol";

contract DeployScWethV2KeeperMainnet is MainnetDeployBase {
    function run() external returns (scWETHv2Keeper deployed) {
        console2.log("--- Deploy scWETHv2Keeper script running ---");

        scWETHv2 scWethV2 = scWETHv2(payable(MainnetAddresses.SCWETHV2));

        vm.startBroadcast(deployerAddress);
        deployed = new scWETHv2Keeper(scWethV2, MainnetAddresses.MULTISIG, MainnetAddresses.KEEPER);
        vm.stopBroadcast();

        console2.log("---Deploy scWETHv2Keeper script done ---");
    }

    function _init() internal override {
        deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        deployerAddress = vm.rememberKey(deployerPrivateKey);
    }
}
