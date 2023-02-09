// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {scLiquity as Vault} from "../src/liquity/scLiquity.sol";

contract DeployScript is CREATE3Script {
    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (Vault v) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        vm.startBroadcast(deployerPrivateKey);
        v = new Vault(ERC20(0x5f98805A4E8be255a32880FDeC7F6728C6568bA0));
        vm.stopBroadcast();
    }
}
