// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {Constants as C} from "../../src/lib/Constants.sol";
import {IAdapter} from "../../src/steth/IAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";

contract AaveV3ScUsdcAdapterTest is Test {
    AaveV3ScUsdcAdapter adapter;
    ERC20 usdc;
    WETH weth;

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(17243956);

        usdc = ERC20(C.USDC);
        weth = WETH(payable(C.WETH));

        adapter = new AaveV3ScUsdcAdapter();
    }

    function test_setApprovals() public {
        adapter.setApprovals();

        assertEq(usdc.allowance(address(adapter), address(adapter.pool())), type(uint256).max, "usdc allowance");
        assertEq(weth.allowance(address(adapter), address(adapter.pool())), type(uint256).max, "weth allowance");
    }

    function test_revokeApprovals() public {
        adapter.setApprovals();

        adapter.revokeApprovals();

        assertEq(usdc.allowance(address(adapter), address(adapter.pool())), 0, "usdc allowance");
        assertEq(weth.allowance(address(adapter), address(adapter.pool())), 0, "weth allowance");
    }

    function test_supply() public {
        uint256 usdcAmount = 10_000e6;
        deal(address(usdc), address(adapter), usdcAmount);
        adapter.setApprovals();

        adapter.supply(usdcAmount);

        assertEq(adapter.getCollateral(address(adapter)), usdcAmount, "supply doesn't match");
    }

    function test_borrow() public {
        uint256 usdcAmount = 10_000e6;
        deal(address(usdc), address(adapter), usdcAmount);
        adapter.setApprovals();
        adapter.supply(usdcAmount);

        uint256 borrowAmount = 3 ether;
        adapter.borrow(borrowAmount);

        assertEq(adapter.getDebt(address(adapter)), borrowAmount, "debt doesn't match");
    }

    function test_repay() public {
        uint256 usdcAmount = 10_000e6;
        uint256 borrowAmount = 3 ether;
        deal(address(usdc), address(adapter), usdcAmount);
        adapter.setApprovals();
        adapter.supply(usdcAmount);
        adapter.borrow(borrowAmount);

        uint256 repayAmount = 1 ether;
        adapter.repay(repayAmount);

        assertEq(adapter.getDebt(address(adapter)), borrowAmount - repayAmount, "debt doesn't match");
    }

    function test_withdraw() public {
        uint256 usdcAmount = 10_000e6;
        uint256 borrowAmount = 3 ether;
        deal(address(usdc), address(adapter), usdcAmount);
        adapter.setApprovals();
        adapter.supply(usdcAmount);
        adapter.borrow(borrowAmount);

        uint256 withdrawAmount = 1000e6;
        adapter.withdraw(withdrawAmount);

        assertEq(adapter.getCollateral(address(adapter)), usdcAmount - withdrawAmount, "supply doesn't match");
        assertEq(usdc.balanceOf(address(adapter)), withdrawAmount, "withdraw doesn't match");
    }

    function test_claimRewards() public {
        vm.expectRevert();
        adapter.claimRewards("");
    }

    function test_getMaxLtv() public {
        assertEq(adapter.getMaxLtv(), 0.74e18, "max ltv");
    }
}
