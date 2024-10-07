// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";
import {Swapper} from "../../src/steth/swapper/Swapper.sol";

contract DeployScript is MainnetDeployBase {
    function run() external returns (Swapper swapper) {
        vm.startBroadcast(deployerAddress);

        swapper = new Swapper();

        vm.stopBroadcast();
    }
}
