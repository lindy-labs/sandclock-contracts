// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {scUSDC as Vault} from "../src/steth/scUSDC.sol";

contract DeployScript is CREATE3Script {
    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (Vault v) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        MockERC20 usdc;

        vm.startBroadcast(deployerPrivateKey);

        usdc = new MockERC20("Mock USDC", "USDC", 6);
        v = new Vault(usdc);
        vm.stopBroadcast();
    }
}
