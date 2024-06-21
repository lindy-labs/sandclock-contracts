// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {MainnetAddresses} from "../base/MainnetAddresses.sol";
import {MainnetDeployBase} from "../base/MainnetDeployBase.sol";
import {scWETHv2} from "../../src/steth/scWETHv2.sol";
import {scSDAI} from "../../src/steth/scSDAI.sol";
import {Swapper} from "../../src/steth/Swapper.sol";
import {PriceConverter} from "../../src/steth/PriceConverter.sol";
import {SparkScDaiAdapter} from "../../src/steth/scDai-adapters/SparkScDaiAdapter.sol";
import {IAdapter} from "../../src/steth/IAdapter.sol";
import {Constants as C} from "../../src/lib/Constants.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ISwapRouter} from "../../src/interfaces/uniswap/ISwapRouter.sol";

import {CREATE3Script} from "../base/CREATE3Script.sol";

contract DeployScDaiMainnet is MainnetDeployBase {
    scWETHv2 scWethV2 = scWETHv2(payable(0x4c406C068106375724275Cbff028770C544a1333));

    function run() external {
        console2.log("--Deploy scDAI script running--");

        require(address(scWethV2) != address(0), "invalid address for ScWethV2 contract");

        _logScriptParams();

        vm.startBroadcast(deployerAddress);

        Swapper swapper = new Swapper();
        PriceConverter priceConverter = new PriceConverter(MainnetAddresses.MULTISIG);
        IAdapter sparkAdapter = new SparkScDaiAdapter();

        console2.log("swapper\t\t", address(swapper));
        console2.log("priceConverter\t\t", address(priceConverter));
        console2.log("sparkAdapter\t\t", address(sparkAdapter));

        // deploy vault
        scSDAI vault = new scSDAI(deployerAddress, keeper, scWethV2, priceConverter, swapper);

        console2.log("scSDAI\t\t", address(vault));

        vault.addAdapter(sparkAdapter);

        // initial deposit
        uint256 daiAmount = _swapWethForDai(0.01 ether);
        ERC20(C.DAI).approve(address(vault), daiAmount);
        vault.depositDai(daiAmount, deployerAddress); // 0.01 ether worth of sDAI

        _transferAdminRoleToMultisig(vault, deployerAddress);

        vm.stopBroadcast();

        console2.log("--Deploy scDAI script done--");
    }

    function _logScriptParams() internal view {
        console2.log("\t script params");
        console2.log("deployer\t\t", address(deployerAddress));
        console2.log("keeper\t\t", address(keeper));
        console2.log("scWethV2\t\t", address(scWethV2));
    }

    function _swapWethForDai(uint256 _amount) internal returns (uint256 amountOut) {
        weth.deposit{value: _amount}();

        weth.approve(C.UNISWAP_V3_SWAP_ROUTER, _amount);

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: abi.encodePacked(C.WETH, uint24(500), C.USDC, uint24(100), C.DAI),
            recipient: deployerAddress,
            deadline: block.timestamp + 1000,
            amountIn: _amount,
            amountOutMinimum: 0
        });

        amountOut = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER).exactInput(params);
    }
}
