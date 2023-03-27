// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {scWETH as Vault} from "../src/steth/scWETH.sol";

contract DeployScript is CREATE3Script {
    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (Vault v) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        uint256 targetLtv = 0.7e18;
        uint256 slippageTolerance = 0.99e18;

        vm.startBroadcast(deployerPrivateKey);
        // v = new Vault(address(this), targetLtv, slippageTolerance);
        vm.stopBroadcast();
    }
}
