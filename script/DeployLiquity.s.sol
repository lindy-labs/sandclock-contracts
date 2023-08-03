// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {MainnetDeployBase} from "./base/MainnetDeployBase.sol";
import {ISwapRouter} from "../src/interfaces/uniswap/ISwapRouter.sol";
import {Constants as C} from "../src/lib/Constants.sol";
import {scLiquity} from "../src/liquity/scLiquity.sol";

/**
 * Mainnet deployment script for scLiquity vault.
 */
contract DeployLiquity is MainnetDeployBase {
    ERC20 constant lusd = ERC20(C.LUSD);

    function run() external returns (scLiquity vault) {
        vm.startBroadcast(deployerAddress);

        vault = new scLiquity(deployerAddress, keeper, lusd);

        // get some LUSD and make the initial deposit (addressing share inflation)
        weth.deposit{value: 0.01 ether}();

        uint256 usdcAmount = _swapWethForUsdc(0.01 ether);
        uint256 lusdAmount = _swapUsdcForLusd(usdcAmount);

        _deposit(vault, lusdAmount);

        _transferAdminRoleToMultisig(vault, deployerAddress);

        vm.stopBroadcast();
    }

    function _swapUsdcForLusd(uint256 _amountIn) internal returns (uint256 amountOut) {
        usdc.approve(C.UNISWAP_V3_SWAP_ROUTER, _amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(usdc),
            tokenOut: address(lusd),
            fee: 500, // 0.05%
            recipient: deployerAddress,
            deadline: block.timestamp + 1000,
            amountIn: _amountIn,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        amountOut = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER).exactInputSingle(params);
    }
}
