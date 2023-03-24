// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {scUSDC as Vault} from "../src/steth/scUSDC.sol";

contract DeployScript is CREATE3Script {
    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (Vault v) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        address scWethAddress = vm.envAddress("SC_WETH_ADDRESS");

        vm.startBroadcast(deployerPrivateKey);
        v = new Vault(address(this), scWETH(payable(scWethAddress)));
        vm.stopBroadcast();
    }
}
