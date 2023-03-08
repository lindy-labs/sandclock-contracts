// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ISwapRouter} from "../../src/interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../../src/interfaces/chainlink/AggregatorV3Interface.sol";

contract MockSwapRouter is ISwapRouter {
    using FixedPointMathLib for uint256;

    // Chainlink pricefeed (USDC -> WETH)
    AggregatorV3Interface public constant usdcToEthPriceFeed =
        AggregatorV3Interface(0x986b5E1e1755e3C2440e960477f25201B0a8bbD4);

    uint256 public slippage = 0.05e8;

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        override
        returns (uint256 amountOut)
    {
        ERC20 tokenIn = ERC20(params.tokenIn);
        ERC20 tokenOut = ERC20(params.tokenOut);

        require(
            tokenIn.allowance(msg.sender, address(this)) >= params.amountIn,
            "MockSwapRouter: INSUFFICIENT_TOKEN_IN_ALLOWANCE"
        );
        require(
            tokenOut.balanceOf(address(this)) >= params.amountOutMinimum,
            "MockSwapRouter: INSUFFICIENT_TOKEN_OUT_BALANCE"
        );

        tokenIn.transferFrom(msg.sender, address(this), params.amountIn);
        tokenOut.transfer(msg.sender, params.amountOutMinimum);

        return params.amountOutMinimum;
    }
}
