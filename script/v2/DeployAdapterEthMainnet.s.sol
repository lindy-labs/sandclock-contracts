// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";
import {MorphoAaveV3ScWethAdapter} from "../../src/steth/scWethV2-adapters/MorphoAaveV3ScWethAdapter.sol";

contract DeployScript is MainnetDeployBase {
    // note: to deploy any other adapter simply change the return type and the line which instantiates the adapter
    function run() external returns (MorphoAaveV3ScWethAdapter adapter) {
        vm.startBroadcast(deployerAddress);

        adapter = new MorphoAaveV3ScWethAdapter();

        vm.stopBroadcast();
    }
}
