// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {DeployLeveragedEth} from "./base/DeployLeveragedEth.sol";

contract DeployScript is DeployLeveragedEth, Test {
    address constant alice = address(0x06);

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
        console2.log("\nexecuting steth fixtures\n");

        fund();

        deposit(alice, address(wethContract), 10e18);

        harvest();
    }

    function fund() internal {
        console2.log("funding");

        deal(alice, 10e18);
        deal(keeper, 10e18);
        deal(address(weth), 100e18);
        deal(address(weth), alice, 100e18);
        deal(address(weth), keeper, 100e18);
    }

    function deposit(address from, address to, uint256 amount) internal {
        console2.log("depositing");

        vm.startPrank(from);
        weth.approve(address(to), type(uint256).max);
        wethContract.deposit(amount, from);
        vm.stopPrank();
    }

    function harvest() internal {
        console2.log("harvesting", keeper);

        vm.prank(keeper);
        wethContract.harvest();
        vm.stopPrank();
    }
}
