// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";

import {DeployLeveragedEth} from "./base/DeployLeveragedEth.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockWETH} from "../test/mocks/MockWETH.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {Constants as C} from "../src/lib/Constants.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {sc4626} from "../src/sc4626.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {scUSDC} from "../src/steth/scUSDC.sol";

contract DeployScript is DeployLeveragedEth, Test {
    using stdStorage for StdStorage;

    uint256 public constant INITIAL_WETH_DEPOSIT = 10e18;

    uint256 public constant INITIAL_WETH_WITHDRAW = 1e18;

    uint256 public constant INITIAL_USDC_DEPOSIT = 100e6;

    uint256 public constant INITIAL_USDC_WITHDRAW = 1e6;

    uint256 public constant INITIAL_WETH_FUNDING = 100e18;

    uint256 public constant INITIAL_USDC_FUNDING = 10000e6;

    function run() external {
        _deploy();
        _fixtures();
    }

    function _fixtures() internal {
        console2.log("\nexecuting steth fixtures");

        _fund();

        _deposit(weth, scWeth, alice, address(scWeth), INITIAL_WETH_DEPOSIT);
        _deposit(weth, scWeth, bob, address(scWeth), INITIAL_WETH_DEPOSIT);
        _deposit(usdc, scUsdc, alice, address(scUsdc), INITIAL_USDC_DEPOSIT);
        _deposit(usdc, scUsdc, bob, address(scUsdc), INITIAL_USDC_DEPOSIT);

        _rebalance(scWeth);

        // double rebalance passes
        _rebalance(scUsdc);
        _rebalance(scUsdc);

        _redeem(scWeth, alice);
        _redeem(scWeth, bob);

        _redeem(scUsdc, alice);
        _redeem(scUsdc, bob);

        _deposit(weth, scWeth, alice, address(scWeth), INITIAL_WETH_DEPOSIT);
        _deposit(weth, scWeth, bob, address(scWeth), INITIAL_WETH_DEPOSIT);
        _deposit(usdc, scUsdc, alice, address(scUsdc), INITIAL_USDC_DEPOSIT);
        _deposit(usdc, scUsdc, bob, address(scUsdc), INITIAL_USDC_DEPOSIT);

        _profit(); // create scUsdc profit scenario

        _divergeLTV(scWeth);
        _divergeLTV(scUsdc);
    }

    function _fund() internal {
        console2.log("funding");

        // Dole out ETH
        deal(alice, INITIAL_WETH_FUNDING);
        deal(bob, INITIAL_WETH_FUNDING);
        deal(keeper, INITIAL_WETH_FUNDING);

        // Dole out WETH
        deal(address(weth), INITIAL_WETH_FUNDING * 2);
        deal(address(weth), alice, INITIAL_WETH_FUNDING);
        deal(address(weth), bob, INITIAL_WETH_FUNDING);

        // Dole out USDC
        deal(address(usdc), alice, INITIAL_USDC_FUNDING);
        deal(address(usdc), bob, INITIAL_USDC_FUNDING);
    }

    function _deposit(ERC20 asset, sc4626 vault, address from, address to, uint256 amount) internal {
        console2.log("depositing", from);

        vm.startPrank(from);
        asset.approve(address(to), type(uint256).max);
        vault.deposit(amount, from);
        vm.stopPrank();
    }

    function _rebalance(scWETH vault) internal {
        console2.log("rebalancing scWETH");

        vm.startPrank(keeper);
        vault.harvest();
        vm.stopPrank();
    }

    function _rebalance(scUSDC vault) internal {
        console2.log("rebalancing scUsdc");

        vm.startPrank(keeper);
        vault.rebalance();
        vm.stopPrank();
    }

    function _profit() internal {
        console2.log("generate profit for scUsdc vault");

        console2.log("scUsdc profit before", scUsdc.getProfit());
        deal(address(weth), address(scWeth), INITIAL_WETH_FUNDING);
        console2.log("scUsdc profit after", scUsdc.getProfit());
    }

    function _redeem(scWETH vault, address redeemer) internal {
        console2.log("redeeming scWETh", redeemer);

        uint256 sharesToRedeem = vault.convertToShares(INITIAL_WETH_WITHDRAW);
        vm.prank(redeemer);
        vault.redeem(sharesToRedeem, redeemer, redeemer);
    }

    function _redeem(scUSDC vault, address redeemer) internal {
        console2.log("redeeming scUsdc", redeemer);

        vm.prank(redeemer);
        vault.withdraw(INITIAL_USDC_WITHDRAW, redeemer, redeemer);
    }

    function _divergeLTV(scWETH vault) internal {
        console2.log("forcing LTV diverge scWETH");
        ERC20 dWeth = ERC20(address(C.AAVE_V3_VAR_DEBT_WETH_TOKEN));

        console2.log("LTV before", vault.getLtv());
        console2.log("dWeth token balance before", dWeth.balanceOf(address(vault)));

        deal(C.AAVE_V3_VAR_DEBT_IMPLEMENTATION_CONTRACT, address(vault), 42e19);

        console2.log("dWeth token balance after", dWeth.balanceOf(address(vault)));
        console2.log("LTV after", vault.getLtv());
    }

    function _divergeLTV(scUSDC vault) internal {
        console2.log("forcing LTV diverge scUsdc");
        ERC20 dWeth = ERC20(address(C.AAVE_V3_VAR_DEBT_WETH_TOKEN));

        console2.log("LTV before", vault.getLtv());
        console2.log("dWeth token balance before", dWeth.balanceOf(address(vault)));

        _setTokenBalance(C.AAVE_V3_VAR_DEBT_IMPLEMENTATION_CONTRACT, address(vault), 42e19);

        console2.log("dWeth token balance after", dWeth.balanceOf(address(vault)));
        console2.log("LTV after", vault.getLtv());
    }

    function _setTokenBalance(address token, address vault, uint256 amount) internal {
        console2.log("setting token balance with stdStore");
        stdstore.target(address(token)).sig(ERC20(token).balanceOf.selector).with_key(vault).checked_write(amount);
    }
}
