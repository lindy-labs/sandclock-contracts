// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {WETH} from "solmate/tokens/WETH.sol";

contract scWETHTest is Test {
    using FixedPointMathLib for uint256;

    string MAINNET_RPC_URL = vm.envString("RPC_URL_MAINNET");
    uint256 mainnetFork;
    uint256 constant ethWstEthMaxLtv = 7735 * 1e14; // 0.7735
    uint256 constant borrowPercentLtv = 5000 * 1e14; // 0.5
    uint256 constant slippageTolerance = 1e16; // 0.1

    // dummy users
    address alice = address(0x06);

    uint256 initAmount = 10e18;

    scWETH vault;
    WETH weth;

    function setUp() public {
        vm.createFork(MAINNET_RPC_URL);
        vm.selectFork(mainnetFork);

        vault = new scWETH(
            ethWstEthMaxLtv,
            borrowPercentLtv,
            slippageTolerance
        );

        weth = vault.weth();

        // top up this and the other addresses with weth
        weth.deposit{value: 20e18}();
        weth.transfer(alice, initAmount);

        // approvals
        weth.approve(address(vault), type(uint256).max);

        vm.prank(alice);
        weth.approve(address(vault), type(uint256).max);
    }

    function testUserDeposit() public {
        uint256 depositAmount = 1e18;
        // user deposit must send weth from the user to the vault
        // and give out shares to the user

        vault.deposit(depositAmount, address(this));

        assertEq(weth.balanceOf(address(this)), initAmount - depositAmount);
        assertEq(weth.balanceOf(address(vault)), depositAmount);
        assertEq(vault.balanceOf(address(this)), depositAmount);

        vm.prank(alice);
        vault.deposit(depositAmount, alice);

        assertEq(weth.balanceOf(address(vault)), depositAmount * 2);
        assertEq(vault.balanceOf(alice), depositAmount);
    }

    function testDepositIntoStrategy() public {
        // taking all the weth into the vault and depositing into strategy by backend
    }
}
