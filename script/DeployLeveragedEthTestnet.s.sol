// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {DeployLeveragedEth} from "./base/DeployLeveragedEth.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockWETH} from "../test/mocks/MockWETH.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";

contract DeployScript is DeployLeveragedEth {
    function deployMockTokens() internal override {
        weth = MockWETH(payable(0xA4584d62299915a288bfe223D298db41cB0c9f7f));
        usdc = MockUSDC(0x30e2B7a907997fDC5a71E377Ece54FAae9F5392D);
    }

    function run() external {
        deploy();
    }
}
