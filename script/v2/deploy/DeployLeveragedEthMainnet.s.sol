// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {SwapperLib} from "src/lib/SwapperLib.sol";
import {DeployScWethV2AndScUsdcV2} from "script/base/DeployScWethV2AndScUsdcV2.sol";
import {scWETH} from "src/steth/scWETH.sol";
import {scUSDC} from "src/steth/scUSDC.sol";

contract DeployLeveragedEthMainnet is DeployScWethV2AndScUsdcV2 {
    function run() external {
        _deploy();

        _postDeployment();
    }

    function _postDeployment() internal {
        vm.startBroadcast(deployerAddress);

        // scWETH
        console2.log("eth deposited for weth");
        _deposit(scWeth, 0.01 ether); // 0.01 WETH
        console2.log("weth deposited into wethContract");

        // scUSDC
        console2.log("eth deposited for weth to swap for usdc");
        SwapperLib._uniswapSwapExactInput(address(weth), address(usdc), 0.01 ether, 0, 500);
        console2.log("eth swapped for USDC");
        _deposit(scUsdc, usdc.balanceOf(address(deployerAddress))); // 0.01 ether worth of USDC
        console2.log("usdc deposited into usdcContract");

        vm.stopBroadcast();
    }
}
