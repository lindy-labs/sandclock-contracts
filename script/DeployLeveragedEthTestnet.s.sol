// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {DeployLeveragedEth} from "./base/DeployLeveragedEth.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockWETH} from "../test/mocks/MockWETH.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

contract DeployScript is DeployLeveragedEth {
    function deployMockTokens () override internal {
        weth = new MockWETH();
        usdc = MockUSDC(0x30e2B7a907997fDC5a71E377Ece54FAae9F5392D);
    }

    function run() external {
        deployMockTokens();
        deployMocks();
        deploy();
    }
}
