// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {Constants as C} from "../../src/lib/Constants.sol";
import {IAdapter} from "../../src/steth/usdc-adapters/IAdapter.sol";
import {EulerAdapter} from "../../src/steth/usdc-adapters/EulerAdapter.sol";

contract EulerAdapterTest is Test {
    using Address for address;

    EulerAdapter adapter;
    ERC20 usdc;
    WETH weth;

    function setUp() public {
        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(16816801);

        usdc = ERC20(C.USDC);
        weth = WETH(payable(C.WETH));

        adapter = new EulerAdapter();
    }

    function test_setApprovals() public {
        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.setApprovals.selector));

        assertEq(usdc.allowance(address(this), address(adapter.protocol())), type(uint256).max, "usdc allowance");
        assertEq(weth.allowance(address(this), address(adapter.protocol())), type(uint256).max, "weth allowance");
    }

    function test_revokeApprovals() public {
        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.setApprovals.selector));

        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.revokeApprovals.selector));

        assertEq(usdc.allowance(address(this), address(adapter.protocol())), 0, "usdc allowance");
        assertEq(weth.allowance(address(this), address(adapter.protocol())), 0, "weth allowance");
    }

    function test_supply() public {
        uint256 usdcAmount = 10_000e6;
        deal(address(usdc), address(this), usdcAmount);
        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.setApprovals.selector));

        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.supply.selector, usdcAmount));

        assertApproxEqAbs(adapter.getCollateral(address(this)), usdcAmount, 1, "supply doesn't match");
    }

    function test_borrow() public {
        uint256 usdcAmount = 10_000e6;
        deal(address(usdc), address(this), usdcAmount);
        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.setApprovals.selector));
        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.supply.selector, usdcAmount));

        uint256 borrowAmount = 3 ether;
        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.borrow.selector, borrowAmount));

        assertEq(adapter.getDebt(address(this)), borrowAmount, "debt doesn't match");
    }

    function test_repay() public {
        uint256 usdcAmount = 10_000e6;
        uint256 borrowAmount = 3 ether;
        deal(address(usdc), address(this), usdcAmount);
        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.setApprovals.selector));
        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.supply.selector, usdcAmount));
        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.borrow.selector, borrowAmount));

        uint256 repayAmount = 1 ether;
        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.repay.selector, repayAmount));

        assertEq(adapter.getDebt(address(this)), borrowAmount - repayAmount, "debt doesn't match");
    }

    function test_withdraw() public {
        uint256 usdcAmount = 10_000e6;
        uint256 borrowAmount = 3 ether;
        deal(address(usdc), address(this), usdcAmount);
        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.setApprovals.selector));
        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.supply.selector, usdcAmount));
        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.borrow.selector, borrowAmount));

        uint256 withdrawAmount = 1000e6;
        address(adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.withdraw.selector, withdrawAmount));

        assertApproxEqAbs(adapter.getCollateral(address(this)), usdcAmount - withdrawAmount, 1, "supply doesn't match");
        assertEq(usdc.balanceOf(address(this)), withdrawAmount, "withdraw doesn't match");
    }
}
