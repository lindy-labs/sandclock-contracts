// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {DeployLeveragedEth} from "./base/DeployLeveragedEth.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {scUSDC} from "../src/steth/scUSDC.sol";
import {sc4626} from "../src/sc4626.sol";
import {Constants as C} from "../src/lib/Constants.sol";
import {ISwapRouter} from "../src/interfaces/uniswap/ISwapRouter.sol";

contract DeployScript is DeployLeveragedEth {
    function run() external {
        _deploy();

        _postDeployment();
    }

    function _postDeployment() internal {
        vm.startBroadcast(_deployerPrivateKey);

        // scWETH
        _weth.deposit{value: 0.01 ether}(); // wrap 0.01 ETH into WETH
        console2.log("eth deposited for weth");
        _deposit(_scWETH, 0.01 ether); // 0.01 WETH
        console2.log("weth deposited into wethContract");

        // scUSDC
        _swapETHForUSDC(0.01 ether);
        console2.log("eth swapped for USDC");
        _deposit(_scUSDC, _usdc.balanceOf(address(_deployerAddress))); // 0.01 ether worth of USDC
        console2.log("usdc deposited into usdcContract");

        vm.stopBroadcast();
    }

    function _deposit(sc4626 vault, uint256 amount) internal {
        vault.asset().approve(address(vault), amount);
        vault.deposit(amount, _deployerAddress);
    }

    function _swapETHForUSDC(uint256 amount) internal {
        _weth.deposit{value: amount}();
        console2.log("eth deposited for weth to swap for usdc");

        _weth.approve(address(_uniswapRouter), amount);
        console2.log("weth approved for swap to usdc");

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(_weth),
            tokenOut: address(_usdc),
            fee: 500, // 0.05%
            recipient: _deployerAddress,
            deadline: block.timestamp + 1000,
            amountIn: amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        _uniswapRouter.exactInputSingle(params);
        console2.log("weth swapped for usdc");
    }
}
