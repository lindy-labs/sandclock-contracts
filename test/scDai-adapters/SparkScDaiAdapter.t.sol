// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {Constants as C} from "../../src/lib/Constants.sol";
import {IAdapter} from "../../src/steth/IAdapter.sol";
import {SparkScDaiAdapter} from "../../src/steth/scDai-adapters/SparkScDaiAdapter.sol";

contract SparkScDaiAdapterTest is Test {
    SparkScDaiAdapter adapter;
    ERC20 dai;
    WETH weth;

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(17243956);

        dai = ERC20(C.DAI);
        weth = WETH(payable(C.WETH));

        adapter = new SparkScDaiAdapter();
    }

    function test_setApprovals() public {
        adapter.setApprovals();

        assertEq(dai.allowance(address(adapter), address(adapter.pool())), type(uint256).max, "dai allowance");
        assertEq(weth.allowance(address(adapter), address(adapter.pool())), type(uint256).max, "weth allowance");
    }

    function test_revokeApprovals() public {
        adapter.setApprovals();

        adapter.revokeApprovals();

        assertEq(dai.allowance(address(adapter), address(adapter.pool())), 0, "dai allowance");
        assertEq(weth.allowance(address(adapter), address(adapter.pool())), 0, "weth allowance");
    }

    function test_supply() public {
        uint256 daiAmount = 10_000e18;
        deal(address(dai), address(adapter), daiAmount);
        adapter.setApprovals();

        adapter.supply(daiAmount);

        assertEq(adapter.getCollateral(address(adapter)), daiAmount, "supply doesn't match");
    }

    function test_borrow() public {
        uint256 daiAmount = 10_000e18;
        deal(address(dai), address(adapter), daiAmount);
        adapter.setApprovals();
        adapter.supply(daiAmount);

        uint256 borrowAmount = 3 ether;
        adapter.borrow(borrowAmount);

        assertEq(adapter.getDebt(address(adapter)), borrowAmount, "debt doesn't match");
    }

    function test_repay() public {
        uint256 daiAmount = 10_000e18;
        uint256 borrowAmount = 3 ether;
        deal(address(dai), address(adapter), daiAmount);
        adapter.setApprovals();
        adapter.supply(daiAmount);
        adapter.borrow(borrowAmount);

        uint256 repayAmount = 1 ether;
        adapter.repay(repayAmount);

        assertApproxEqRel(adapter.getDebt(address(adapter)), borrowAmount - repayAmount, 100, "debt doesn't match");
    }

    function test_withdraw() public {
        uint256 daiAmount = 10_000e18;
        uint256 borrowAmount = 3 ether;
        deal(address(dai), address(adapter), daiAmount);
        adapter.setApprovals();
        adapter.supply(daiAmount);
        adapter.borrow(borrowAmount);

        uint256 withdrawAmount = 1000e18;
        adapter.withdraw(withdrawAmount);

        assertEq(adapter.getCollateral(address(adapter)), daiAmount - withdrawAmount, "supply doesn't match");
        assertEq(dai.balanceOf(address(adapter)), withdrawAmount, "withdraw doesn't match");
    }

    function test_claimRewards() public {
        vm.expectRevert();
        adapter.claimRewards("");
    }

    function test_getMaxLtv() public {
        assertEq(adapter.getMaxLtv(), 0.74e18, "max ltv");
    }
}
