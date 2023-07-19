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

contract DeployLeveragedEthTestnet is DeployLeveragedEth, Test {
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

    function _deposit(ERC20 _asset, sc4626 _vault, address _from, address _to, uint256 _amount) internal {
        console2.log("depositing", _from);

        vm.startPrank(_from);
        _asset.approve(address(_to), type(uint256).max);
        _vault.deposit(_amount, _from);
        vm.stopPrank();
    }

    function _rebalance(scWETH _vault) internal {
        console2.log("rebalancing scWETH");

        vm.startPrank(keeper);
        _vault.harvest();
        vm.stopPrank();
    }

    function _rebalance(scUSDC _vault) internal {
        console2.log("rebalancing scUsdc");

        vm.startPrank(keeper);
        _vault.rebalance();
        vm.stopPrank();
    }

    function _profit() internal {
        console2.log("generate profit for scUsdc vault");

        console2.log("scUsdc profit before", scUsdc.getProfit());
        deal(address(weth), address(scWeth), INITIAL_WETH_FUNDING);
        console2.log("scUsdc profit after", scUsdc.getProfit());
    }

    function _redeem(scWETH _vault, address _redeemer) internal {
        console2.log("redeeming scWETh", _redeemer);

        uint256 sharesToRedeem = _vault.convertToShares(INITIAL_WETH_WITHDRAW);
        vm.prank(_redeemer);
        _vault.redeem(sharesToRedeem, _redeemer, _redeemer);
    }

    function _redeem(scUSDC _vault, address _redeemer) internal {
        console2.log("redeeming scUsdc", _redeemer);

        vm.prank(_redeemer);
        _vault.withdraw(INITIAL_USDC_WITHDRAW, _redeemer, _redeemer);
    }
}
