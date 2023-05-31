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
        deploy();

        postDeployment();
    }

    function postDeployment() internal {
        vm.startBroadcast(deployerPrivateKey);

        // scWETH
        weth.deposit{value: 0.01 ether}(); // wrap 0.01 ETH into WETH
        console2.log("eth deposited for weth");
        deposit(wethContract, 0.01 ether); // 0.01 WETH
        console2.log("weth deposited into wethContract");

        // scUSDC
        swapETHForUSDC(0.01 ether);
        console2.log("eth swapped for USDC");
        deposit(usdcContract, usdc.balanceOf(address(deployerAddress))); // 0.01 ether worth of USDC
        console2.log("usdc deposited into usdcContract");

        vm.stopBroadcast();
    }

    function deposit(sc4626 vault, uint256 amount) internal {
        vault.asset().approve(address(vault), amount);
        vault.deposit(amount, deployerAddress);
    }

    function swapETHForUSDC(uint256 amount) internal {
        weth.deposit{value: amount}();
        console2.log("eth deposited for weth to swap for usdc");

        weth.approve(address(uniswapRouter), amount);
        console2.log("weth approved for swap to usdc");

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(usdc),
            fee: 500, // 0.05%
            recipient: deployerAddress,
            deadline: block.timestamp + 1000,
            amountIn: amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        uniswapRouter.exactInputSingle(params);
        console2.log("weth swapped for usdc");
    }
}
