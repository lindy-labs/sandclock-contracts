// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {DeployLeveragedEth} from "./base/DeployLeveragedEth.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockWETH} from "../test/mocks/MockWETH.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {sc4626} from "../src/sc4626.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {scUSDC} from "../src/steth/scUSDC.sol";

contract DeployScript is DeployLeveragedEth, Test {
    using FixedPointMathLib for uint256;

    address constant alice = address(0x06);
    address constant bob = address(0x07);

    function deployMockTokens() internal override {
        weth = new MockWETH();
        usdc = new MockUSDC();
    }

    function run() external {
        if (block.chainid != 31337) {
            console2.log("Not local");

            return;
        }

        deployMockTokens();
        deployMocks();
        deploy();
        fixtures();
    }

    function fixtures() internal {
        console2.log("\nexecuting steth fixtures");

        fund();

        deposit(wethContract);
        // deposit(usdcContract);

        rebalance(wethContract);
        // rebalance(usdcContract);

        redeem(alice);
    }

    function deposit(sc4626 vaultToken) internal {
        deposit(alice, address(vaultToken), 10e18);
        deposit(bob, address(vaultToken), 10e18);
    }

    function fund() internal {
        console2.log("funding");

        // Dole out ETH
        deal(alice, 10e18);
        deal(bob, 10e18);
        deal(keeper, 10e18);
        deal(address(curveEthStEthPool), 100e18);

        // Dole out WETH
        deal(address(weth), 100e18);
        deal(address(weth), alice, 100e18);
        deal(address(weth), bob, 100e18);
    }

    function deposit(address from, address to, uint256 amount) internal {
        console2.log("depositing", from);

        vm.startPrank(from);
        weth.approve(address(to), type(uint256).max);
        wethContract.deposit(amount, from);
        vm.stopPrank();
    }

    function rebalance(scWETH vaultToken) internal {
        console2.log("rebalancing");

        vm.prank(keeper);
        vaultToken.harvest();
        vm.stopPrank();
    }

    function rebalance(scUSDC vaultToken) internal {
        console2.log("rebalancing");

        vm.prank(keeper);
        vaultToken.rebalance();
        vm.stopPrank();
    }

    function redeem(address redeemer) internal {
        console2.log("redeeming", redeemer);

        uint256 stEthToEthSlippage = 0.99e18;
        curveEthStEthPool.setSlippage(stEthToEthSlippage);

        uint256 withdrawAmount = 1e18;
        uint256 sharesToReddem = wethContract.convertToShares(withdrawAmount);
        vm.prank(redeemer);
        wethContract.redeem(sharesToReddem, redeemer, redeemer);
    }
}
