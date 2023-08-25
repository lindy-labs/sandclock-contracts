// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";
import {MorphoAaveV3ScWethAdapter} from "../../src/steth/scWethV2-adapters/MorphoAaveV3ScWethAdapter.sol";
import {AaveV3ScWethAdapter} from "../../src/steth/scWethV2-adapters/AaveV3ScWethAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";

contract DeployScript is MainnetDeployBase {
    // note: to deploy any other adapter simply change the return type and the line which instantiates the adapter
    function run()
        external
        returns (AaveV3ScWethAdapter aaveV3ScWethAdapter, AaveV3ScUsdcAdapter aaveV3ScUsdcAdapter)
    {
        vm.startBroadcast(deployerAddress);

        aaveV3ScWethAdapter = new AaveV3ScWethAdapter();
        aaveV3ScUsdcAdapter = new AaveV3ScUsdcAdapter();

        vm.stopBroadcast();
    }
}
