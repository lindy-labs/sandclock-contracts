// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {DeployLeveragedEth} from "./base/DeployLeveragedEth.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockWETH} from "../test/mocks/MockWETH.sol";
import {MockUSDC} from "../test/mocks/MockUSDC.sol";
import {Constants as C} from "../src/lib/Constants.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {sc4626} from "../src/sc4626.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {scUSDC} from "../src/steth/scUSDC.sol";
import {IVariableDebtToken} from "aave-v3-core/contracts/interfaces/IVariableDebtToken.sol";

contract DeployScript is DeployLeveragedEth, Test {
    function run() external {
        _deploy();
        _fixtures();
    }

    function _fixtures() internal {
        console2.log("\nexecuting steth fixtures");

        _fund();

        _depositForUsers(_weth, _scWETH);
        _depositForUsers(_usdc, _scUSDC);

        _rebalance(_scWETH);

        // double rebalance passes
        _rebalance(_scUSDC);
        _rebalance(_scUSDC);

        _redeem(_scWETH, _alice);
        _redeem(_scWETH, _bob);

        _redeem(_scUSDC, _alice);
        _redeem(_scUSDC, _bob);

        _depositForUsers(_usdc, _scUSDC);
        _depositForUsers(_weth, _scWETH);

        _rebalance(_scUSDC);
        _rebalance(_scWETH);

        _profit();

        _rebalance(_scUSDC);
    }

    function _depositForUsers(ERC20 asset, sc4626 vaultToken) internal {
        console2.log("depositing for users", 100 * 10 ** asset.decimals());
        _deposit(asset, vaultToken, _alice, address(vaultToken), 10 * 10 ** asset.decimals());
        _deposit(asset, vaultToken, _bob, address(vaultToken), 10 * 10 ** asset.decimals());
    }

    function _fund() internal {
        console2.log("funding");

        // Dole out ETH
        deal(_alice, 10e18);
        deal(_bob, 10e18);
        deal(_keeper, 10e18);

        // Dole out WETH
        deal(address(_weth), 200e18);
        deal(address(_weth), _alice, 100e18);
        deal(address(_weth), _bob, 100e18);

        // Dole out USDC
        deal(address(_usdc), _alice, 100e6);
        deal(address(_usdc), _bob, 100e6);
    }

    function _deposit(ERC20 asset, sc4626 vault, address from, address to, uint256 amount) internal {
        console2.log("depositing", from);

        vm.startPrank(from);
        asset.approve(address(to), type(uint256).max);
        vault.deposit(amount, from);
        vm.stopPrank();
    }

    function _rebalance(scWETH vaultToken) internal {
        console2.log("rebalancing scWETH");

        vm.startPrank(_keeper);
        vaultToken.harvest();
        vm.stopPrank();
    }

    function _rebalance(scUSDC vaultToken) internal {
        console2.log("rebalancing scUSDC");

        vm.startPrank(_keeper);
        vaultToken.rebalance();
        vm.stopPrank();
    }

    function _profit() internal {
        console2.log("generate profit for scUSDC vault");

        console2.log("scUSDC profit before", _scUSDC.getProfit());
        deal(address(_weth), address(_scWETH), 100e18);
        console2.log("scUSDC profit after", _scUSDC.getProfit());
    }

    function _redeem(scWETH vaultToken, address redeemer) internal {
        console2.log("redeeming scWETh", redeemer);

        uint256 withdrawAmount = 1e18;
        uint256 sharesToRedeem = vaultToken.convertToShares(withdrawAmount);
        vm.prank(redeemer);
        vaultToken.redeem(sharesToRedeem, redeemer, redeemer);
    }   

    function _redeem(scUSDC vaultToken, address redeemer) internal {
        console2.log("redeeming scUSDC", redeemer);

        uint256 withdrawAmount = 1e6;
        vm.prank(redeemer);
        vaultToken.withdraw(withdrawAmount, redeemer, redeemer);
    }
}