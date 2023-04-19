// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
// import "forge-std/Test.sol";
import {DeployLeveragedEth} from "./base/DeployLeveragedEth.sol";

contract DeployScript is DeployLeveragedEth {
    function run() external {
        if (block.chainid != 31337) {
            console2.log("Not local");

            return;
        }

        deployMocks();
        deploy();
        fixtures();
    }

    function fixtures() internal {
        console2.log("executin steth fixtures");

        // fixture stuff here
    }
}
