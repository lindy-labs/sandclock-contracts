// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {DeployLeveragedEth} from "./base/DeployLeveragedEth.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {scUSDC} from "../src/steth/scUSDC.sol";
import {sc4626} from "../src/sc4626.sol";
import {Constants as C} from "../src/lib/Constants.sol";
import {ISwapRouter} from "../src/interfaces/uniswap/ISwapRouter.sol";

contract DeployLeveragedEthMainnet is DeployLeveragedEth {
    function run() external {
        _deploy();

        _postDeployment();
    }

    function _postDeployment() internal {
        vm.startBroadcast(deployerPrivateKey);

        // scWETH
        weth.deposit{value: 0.01 ether}(); // wrap 0.01 ETH into WETH
        console2.log("eth deposited for weth");
        _deposit(scWeth, 0.01 ether); // 0.01 WETH
        console2.log("weth deposited into wethContract");

        // scUSDC
        weth.deposit{value: 0.01 ether}();
        console2.log("eth deposited for weth to swap for usdc");
        _swapWethForUsdc(0.01 ether);
        console2.log("eth swapped for USDC");
        _deposit(scUsdc, usdc.balanceOf(address(deployerAddress))); // 0.01 ether worth of USDC
        console2.log("usdc deposited into usdcContract");

        vm.stopBroadcast();
    }
}
