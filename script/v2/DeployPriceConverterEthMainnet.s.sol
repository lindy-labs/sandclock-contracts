// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";
import {MainnetAddresses} from "../base/MainnetAddresses.sol";
import {PriceConverter} from "../../src/steth/PriceConverter.sol";

contract DeployScript is MainnetDeployBase {
    function run() external returns (PriceConverter priceConverter) {
        vm.startBroadcast(deployerAddress);

        priceConverter = new PriceConverter(MainnetAddresses.MULTISIG);

        vm.stopBroadcast();
    }
}
