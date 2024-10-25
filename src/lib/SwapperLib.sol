// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {Constants as C} from "./Constants.sol";
import {AmountReceivedBelowMin} from "src/errors/scErrors.sol";
import {ISwapRouter} from "src/interfaces/uniswap/ISwapRouter.sol";
import {ILido} from "src/interfaces/lido/ILido.sol";
import {IwstETH} from "src/interfaces/lido/IwstETH.sol";
import {ICurvePool} from "src/interfaces/curve/ICurvePool.sol";

/**
 * @title SwapperLib
 * @notice Library providing utility functions for token swaps using Uniswap V3 and arbitrary routers.
 * @dev This library is intended to be used by contracts facilitating token swaps.
 */
library SwapperLib {
    using SafeTransferLib for ERC20;
    using Address for address;

    /// @notice Uniswap V3 Swap Router
    ISwapRouter public constant swapRouter = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER);

    /// @notice Curve ETH/stETH Pool
    ICurvePool public constant curvePool = ICurvePool(C.CURVE_ETH_STETH_POOL);

    /// @notice Wrapped Ether (WETH) Token
    WETH public constant weth = WETH(payable(C.WETH));

    /// @notice Lido stETH Token
    ILido public constant stEth = ILido(C.STETH);

    /// @notice Wrapped stETH Token
    IwstETH public constant wstEth = IwstETH(C.WSTETH);

    /**
     * @notice Swap tokens on Uniswap V3 using the exact input single function.
     * @param _tokenIn The address of the token to swap from.
     * @param _tokenOut The address of the token to swap to.
     * @param _amountIn The amount of `_tokenIn` to swap.
     * @param _amountOutMin The minimum amount of `_tokenOut` to receive.
     * @param _poolFee The fee tier of the Uniswap V3 pool.
     * @return amountOut The amount of `_tokenOut` received from the swap.
     */
    function _uniswapSwapExactInput(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint24 _poolFee
    ) internal returns (uint256 amountOut) {
        amountOut = _uniswapSwapExactInput(_tokenIn, _tokenOut, address(this), _amountIn, _amountOutMin, _poolFee);
    }

    /**
     * @notice Swap tokens on Uniswap V3 using the exact input single function.
     * @param _tokenIn The address of the token to swap from.
     * @param _tokenOut The address of the token to swap to.
     * @param _recipient The address to receive the output tokens.
     * @param _amountIn The amount of `_tokenIn` to swap.
     * @param _amountOutMin The minimum amount of `_tokenOut` to receive.
     * @param _poolFee The fee tier of the Uniswap V3 pool.
     * @return amountOut The amount of `_tokenOut` received from the swap.
     */
    function _uniswapSwapExactInput(
        address _tokenIn,
        address _tokenOut,
        address _recipient,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint24 _poolFee
    ) internal returns (uint256 amountOut) {
        ERC20(_tokenIn).safeApprove(address(swapRouter), _amountIn);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            fee: _poolFee,
            recipient: _recipient,
            deadline: block.timestamp + 24 hours,
            amountIn: _amountIn,
            amountOutMinimum: _amountOutMin,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(params);
    }

    /**
     * @notice Swap tokens on Uniswap V3 using exact input multi-hop.
     * @param _tokenIn The address of the token to swap from.
     * @param _amountIn The amount of `_tokenIn` to swap.
     * @param _amountOutMin The minimum amount of the output token to receive.
     * @param _path The encoded path for the swap, including tokens and fees.
     * @return amountOut The amount of output tokens received from the swap.
     */
    function _uniswapSwapExactInputMultihop(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes memory _path
    ) internal returns (uint256 amountOut) {
        amountOut = _uniswapSwapExactInputMultihop(_tokenIn, _amountIn, _amountOutMin, _path, address(this));
    }

    /**
     * @notice Swap tokens on Uniswap V3 using exact input multi-hop.
     * @param _tokenIn The address of the token to swap from.
     * @param _amountIn The amount of `_tokenIn` to swap.
     * @param _amountOutMin The minimum amount of the output token to receive.
     * @param _path The encoded path for the swap, including tokens and fees.
     * @param _recipient The address to receive the output tokens.
     * @return amountOut The amount of output tokens received from the swap.
     */
    function _uniswapSwapExactInputMultihop(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes memory _path,
        address _recipient
    ) internal returns (uint256 amountOut) {
        ERC20(_tokenIn).safeApprove(address(swapRouter), _amountIn);

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: _path,
            recipient: _recipient,
            deadline: block.timestamp + 24 hours,
            amountIn: _amountIn,
            amountOutMinimum: _amountOutMin
        });

        amountOut = swapRouter.exactInput(params);
    }

    /**
     * @notice Swap tokens on Uniswap V3 using exact output multi-hop.
     * @param _tokenIn The address of the token to swap from.
     * @param _amountOut The exact amount of the output token desired.
     * @param _amountInMaximum The maximum amount of `_tokenIn` willing to spend.
     * @param _path The encoded path for the swap, reversed (output token to input token).
     * @return amountIn The amount of `_tokenIn` spent to receive `_amountOut` of the output token.
     */
    function _uniswapSwapExactOutputMultihop(
        address _tokenIn,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        bytes memory _path
    ) internal returns (uint256 amountIn) {
        ERC20(_tokenIn).safeApprove(address(swapRouter), _amountInMaximum);

        ISwapRouter.ExactOutputParams memory params = ISwapRouter.ExactOutputParams({
            path: _path,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: _amountOut,
            amountInMaximum: _amountInMaximum
        });

        amountIn = swapRouter.exactOutput(params);

        // Reset approval to zero
        ERC20(_tokenIn).safeApprove(address(swapRouter), 0);
    }

    /**
     * @notice Swap tokens on Uniswap V3 using the exact output single function.
     * @param _tokenIn The address of the token to swap from.
     * @param _tokenOut The address of the token to receive.
     * @param _amountOut The exact amount of `_tokenOut` desired.
     * @param _amountInMaximum The maximum amount of `_tokenIn` willing to spend.
     * @param _poolFee The fee tier of the Uniswap V3 pool.
     * @return amountIn The amount of `_tokenIn` spent to receive `_amountOut` of `_tokenOut`.
     */
    function _uniswapSwapExactOutput(
        address _tokenIn,
        address _tokenOut,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        uint24 _poolFee
    ) internal returns (uint256 amountIn) {
        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: _tokenIn,
            tokenOut: _tokenOut,
            fee: _poolFee,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: _amountOut,
            amountInMaximum: _amountInMaximum,
            sqrtPriceLimitX96: 0
        });

        ERC20(_tokenIn).safeApprove(address(swapRouter), _amountInMaximum);

        amountIn = swapRouter.exactOutputSingle(params);

        // Reset approval to zero
        ERC20(_tokenIn).safeApprove(address(swapRouter), 0);
    }

    /**
     * @notice Swap tokens using an arbitrary swap router.
     * @param _router The address of the swap router contract.
     * @param _tokenIn The address of the token to swap from.
     * @param _tokenOut The address of the token to receive.
     * @param _amountIn The amount of `_tokenIn` to swap.
     * @param _amountOutMin The minimum amount of `_tokenOut` to receive.
     * @param _swapData Arbitrary data to pass to the swap router.
     * @return amountReceived The amount of `_tokenOut` received from the swap.
     */
    function _swapTokens(
        address _router,
        address _tokenIn,
        address _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes calldata _swapData
    ) internal returns (uint256 amountReceived) {
        uint256 tokenOutInitialBalance = ERC20(_tokenOut).balanceOf(address(this));

        ERC20(_tokenIn).safeApprove(_router, _amountIn);

        _router.functionCall(_swapData);

        amountReceived = ERC20(_tokenOut).balanceOf(address(this)) - tokenOutInitialBalance;

        // Check if the received amount is at least the minimum required
        if (amountReceived < _amountOutMin) revert AmountReceivedBelowMin();

        // Reset approval to zero
        ERC20(_tokenIn).approve(_router, 0);
    }
}
