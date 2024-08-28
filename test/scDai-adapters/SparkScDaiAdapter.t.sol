// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {Constants as C} from "../../src/lib/Constants.sol";
import {IAdapter} from "../../src/steth/IAdapter.sol";
import {SparkScSDaiAdapter} from "../../src/steth/scSDai-adapters/SparkScSDaiAdapter.sol";

contract SparkScDaiAdapterTest is Test {
    SparkScSDaiAdapter adapter;
    ERC20 sDai;
    WETH weth;

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(19774188);

        sDai = ERC20(C.SDAI);
        weth = WETH(payable(C.WETH));

        adapter = new SparkScSDaiAdapter();
    }

    function test_setApprovals() public {
        adapter.setApprovals();

        assertEq(sDai.allowance(address(adapter), address(adapter.pool())), type(uint256).max, "sDai allowance");
        assertEq(weth.allowance(address(adapter), address(adapter.pool())), type(uint256).max, "weth allowance");
    }

    function test_revokeApprovals() public {
        adapter.setApprovals();

        adapter.revokeApprovals();

        assertEq(sDai.allowance(address(adapter), address(adapter.pool())), 0, "sDai allowance");
        assertEq(weth.allowance(address(adapter), address(adapter.pool())), 0, "weth allowance");
    }

    function test_supply() public {
        uint256 sDaiAmount = 10_000e18;
        deal(address(sDai), address(adapter), sDaiAmount);
        adapter.setApprovals();

        adapter.supply(sDaiAmount);

        assertEq(adapter.getCollateral(address(adapter)), sDaiAmount, "supply doesn't match");
    }

    function test_borrow() public {
        uint256 sDaiAmount = 10_000e18;
        deal(address(sDai), address(adapter), sDaiAmount);
        adapter.setApprovals();
        adapter.supply(sDaiAmount);

        uint256 borrowAmount = 3 ether;
        adapter.borrow(borrowAmount);

        assertEq(adapter.getDebt(address(adapter)), borrowAmount, "debt doesn't match");
    }

    function test_repay() public {
        uint256 sDaiAmount = 10_000e18;
        uint256 borrowAmount = 3 ether;
        deal(address(sDai), address(adapter), sDaiAmount);
        adapter.setApprovals();
        adapter.supply(sDaiAmount);
        adapter.borrow(borrowAmount);

        uint256 repayAmount = 1 ether;
        adapter.repay(repayAmount);

        assertApproxEqRel(adapter.getDebt(address(adapter)), borrowAmount - repayAmount, 100, "debt doesn't match");
    }

    function test_withdraw() public {
        uint256 sDaiAmount = 10_000e18;
        uint256 borrowAmount = 3 ether;
        deal(address(sDai), address(adapter), sDaiAmount);
        adapter.setApprovals();
        adapter.supply(sDaiAmount);
        adapter.borrow(borrowAmount);

        uint256 withdrawAmount = 100e18;
        adapter.withdraw(withdrawAmount);

        assertEq(adapter.getCollateral(address(adapter)), sDaiAmount - withdrawAmount, "supply doesn't match");
        assertEq(sDai.balanceOf(address(adapter)), withdrawAmount, "withdraw doesn't match");
    }

    function test_withdrawAll() public {
        uint256 sDaiAmount = 10_000e18;
        uint256 borrowAmount = 3 ether;
        deal(address(sDai), address(adapter), sDaiAmount);
        adapter.setApprovals();
        adapter.supply(sDaiAmount);
        adapter.borrow(borrowAmount);

        adapter.repay(borrowAmount);
        adapter.withdraw(sDaiAmount);

        assertEq(adapter.getCollateral(address(adapter)), 0, "supply doesn't match");
        assertEq(sDai.balanceOf(address(adapter)), sDaiAmount, "withdraw doesn't match");
    }

    function test_claimRewards() public {
        vm.expectRevert();
        adapter.claimRewards("");
    }

    function test_getMaxLtv() public {
        assertEq(adapter.getMaxLtv(), 0.79e18, "max ltv");
    }
}
