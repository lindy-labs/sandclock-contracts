// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {CREATE3Script} from "./base/CREATE3Script.sol";
import {Constants as C} from "../src/lib/Constants.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {scUSDC} from "../src/steth/scUSDC.sol";

contract DeployScript is CREATE3Script {
    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (scWETH scWeth, scUSDC scUsdc) {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        uint256 targetLtv = 0.7e18;
        uint256 slippageTolerance = 0.99e18;

        vm.startBroadcast(deployerPrivateKey);
        scWeth = new scWETH(C.WETH, address(this), targetLtv, slippageTolerance);
        scUsdc = new scUSDC(address(this), scWeth);
        vm.stopBroadcast();
    }
}
