// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {DeployLeveragedEth} from "./base/DeployLeveragedEth.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockWETH} from "../test/mocks/MockWETH.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {sc4626} from "../src/sc4626.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {scUSDC} from "../src/steth/scUSDC.sol";
import {Constants as C} from "../src/lib/Constants.sol";

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

        deploy();
        fixtures();
    }

    function fixtures() internal {
        console2.log("\nexecuting steth fixtures");

        fund();

        depositForUsers(weth, wethContract);
        depositForUsers(usdc, usdcContract);

        rebalance(wethContract);
        rebalance(usdcContract);

        profit();

        redeem(alice);

        depositForUsers(weth, wethContract);
        depositForUsers(usdc, usdcContract);
    }

    function depositForUsers(ERC20 asset, sc4626 vaultToken) internal {
        console2.log("depositing for users", 100 * 10 ** asset.decimals());
        deposit(asset, vaultToken, alice, address(vaultToken), 10 * 10 ** asset.decimals());
        deposit(asset, vaultToken, bob, address(vaultToken), 10 * 10 ** asset.decimals());
    }

    function fund() internal {
        console2.log("funding");

        // Dole out ETH
        deal(alice, 10e18);
        deal(bob, 10e18);
        deal(keeper, 10e18);
        deal(address(curveEthStEthPool), 100e18);

        // Dole out WETH
        deal(address(weth), 200e18);
        deal(address(weth), alice, 100e18);
        deal(address(weth), bob, 100e18);

        // Dole out USDC
        deal(address(usdc), alice, 100e6);
        deal(address(usdc), bob, 100e6);
    }

    function deposit(ERC20 asset, sc4626 vault, address from, address to, uint256 amount) internal {
        console2.log("depositing", from);

        vm.startPrank(from);
        asset.approve(address(to), type(uint256).max);
        vault.deposit(amount, from);
        vm.stopPrank();
    }

    function rebalance(scWETH vaultToken) internal {
        console2.log("rebalancing scWETH");

        vm.startPrank(keeper);
        vaultToken.harvest();
        vm.stopPrank();
    }

    function rebalance(scUSDC vaultToken) internal {
        console2.log("rebalancing scUSDC");

        vm.startPrank(keeper);
        vaultToken.rebalance();
        vm.stopPrank();
    }

    function profit() internal {
        console2.log("generate profit for scUSDC vault");

        (, uint256 borrowAmount) = aavePool.book(address(wethContract), address(weth));

        // Reduce amount of debt so that there is less debt than the original to create profit
        vm.startPrank(address(wethContract));
        deal(address(weth), address(wethContract), 100e18);
        aavePool.repay(
            address(weth),
            borrowAmount / 2,
            C.AAVE_VAR_INTEREST_RATE_MODE, // does not impact mock
            address(wethContract) // does not impact mock
        );
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
