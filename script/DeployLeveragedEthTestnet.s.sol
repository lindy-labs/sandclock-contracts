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

contract DeployScript is DeployLeveragedEth, Test {
    function run() external {
        _deploy();
        _fixtures();
    }

    function _fixtures() internal {
        console2.log("\nexecuting steth fixtures");

        _fund();

        _depositForUsers(_weth, _wethContract);
        _depositForUsers(_usdc, _usdcContract);

        _rebalance(_wethContract);
        _rebalance(_usdcContract);

        _profit();

        // _redeem(_alice);

        // depositForUsers(weth, wethContract);
        // depositForUsers(usdc, usdcContract);
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
        // deal(address(curveEthStEthPool), 100e18);

        // Dole out WETH
        deal(address(_weth), 200e18);
        deal(address(_weth), _alice, 100e18);
        deal(address(_weth), _bob, 100e18);
        // deal(address(weth), keeper, 100e18);

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

        console2.log("scUSDC profit before", _usdcContract.getProfit());
        vm.etch(C.AAVAAVE_VAR_DEBT_WETH_TOKEN, address(_weth).code);
        console2.log("scUSDC profit after", _usdcContract.getProfit());
    }

    // function _redeem(address redeemer) internal {
    //     console2.log("redeeming", redeemer);

    //     uint256 stEthToEthSlippage = 0.99e18;
    //     _curveEthStEthPool.setSlippage(stEthToEthSlippage);

    //     uint256 withdrawAmount = 1e18;
    //     uint256 sharesToReddem = _wethContract.convertToShares(withdrawAmount);
    //     vm.prank(redeemer);
    //     _wethContract.redeem(sharesToReddem, redeemer, redeemer);
    // }
}
