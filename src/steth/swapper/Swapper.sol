// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../../interfaces/lido/ILido.sol";
import {IwstETH} from "../../interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../../interfaces/curve/ICurvePool.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {AmountReceivedBelowMin} from "../../errors/scErrors.sol";
import {Constants as C} from "../../lib/Constants.sol";
import {IScWETHSwapper} from "./IScWETHSwapper.sol";
import {SwapperLib} from "./SwapperLib.sol";
import {UniversalSwapper} from "./UniversalSwapper.sol";

/**
 * @title Swapper
 * @notice Contract providing swapping functionalities involving WETH, stETH, and wstETH using Lido and Curve protocols.
 * @dev This contract is intended to be used only via delegate calls.
 * @dev Using this contract directly for swaps might result in reverts.
 */
contract Swapper is IScWETHSwapper, UniversalSwapper {
    using SafeTransferLib for ERC20;
    using Address for address;

    /// @notice Curve ETH/stETH Pool
    ICurvePool public constant curvePool = ICurvePool(C.CURVE_ETH_STETH_POOL);

    /// @notice Wrapped Ether (WETH) Token
    WETH public constant weth = WETH(payable(C.WETH));

    /// @notice Lido stETH Token
    ILido public constant stEth = ILido(C.STETH);

    /// @notice Wrapped stETH Token
    IwstETH public constant wstEth = IwstETH(C.WSTETH);

    /**
     * @notice Swap tokens on Uniswap V3 using exact input multi-hop.
     * @param _tokenIn The address of the token to swap from.
     * @param _amountIn The amount of `_tokenIn` to swap.
     * @param _amountOutMin The minimum amount of output tokens to receive.
     * @param _path The encoded path for the swap.
     * @return amountOut The amount of output tokens received from the swap.
     */
    function uniswapSwapExactInputMultihop(
        address _tokenIn,
        uint256 _amountIn,
        uint256 _amountOutMin,
        bytes memory _path
    ) external returns (uint256 amountOut) {
        amountOut = SwapperLib._uniswapSwapExactInputMultihop(_tokenIn, _amountIn, _amountOutMin, _path);
    }

    /**
     * @notice Swap tokens on Uniswap V3 using exact input single function.
     * @param _tokenIn The ERC20 token to swap from.
     * @param _tokenOut The ERC20 token to swap to.
     * @param _amountIn The amount of `_tokenIn` to swap.
     * @param _amountOutMin The minimum amount of `_tokenOut` to receive.
     * @param _poolFee The fee tier of the Uniswap V3 pool.
     * @return amountOut The amount of `_tokenOut` received from the swap.
     */
    function uniswapSwapExactInput(
        ERC20 _tokenIn,
        ERC20 _tokenOut,
        uint256 _amountIn,
        uint256 _amountOutMin,
        uint24 _poolFee
    ) external returns (uint256 amountOut) {
        amountOut =
            SwapperLib._uniswapSwapExactInput(address(_tokenIn), address(_tokenOut), _amountIn, _amountOutMin, _poolFee);
    }

    /**
     * @notice Swap tokens on Uniswap V3 using exact output multi-hop.
     * @param _tokenIn The address of the token to swap from.
     * @param _amountOut The exact amount of output tokens desired.
     * @param _amountInMaximum The maximum amount of `_tokenIn` willing to spend.
     * @param _path The encoded path for the swap, reversed.
     * @return amountIn The amount of `_tokenIn` spent to receive `_amountOut` of the output token.
     */
    function uniswapSwapExactOutputMultihop(
        address _tokenIn,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        bytes memory _path
    ) public returns (uint256 amountIn) {
        amountIn = SwapperLib._uniswapSwapExactOutputMultihop(_tokenIn, _amountOut, _amountInMaximum, _path);
    }

    /**
     * @notice Swap tokens on Uniswap V3 using exact output single function.
     * @param _tokenIn The ERC20 token to swap from.
     * @param _tokenOut The ERC20 token to receive.
     * @param _amountOut The exact amount of `_tokenOut` desired.
     * @param _amountInMaximum The maximum amount of `_tokenIn` willing to spend.
     * @param _poolFee The fee tier of the Uniswap V3 pool.
     * @return amountIn The amount of `_tokenIn` spent to receive `_amountOut` of `_tokenOut`.
     */
    function uniswapSwapExactOutput(
        ERC20 _tokenIn,
        ERC20 _tokenOut,
        uint256 _amountOut,
        uint256 _amountInMaximum,
        uint24 _poolFee
    ) public returns (uint256 amountIn) {
        amountIn = SwapperLib._uniswapSwapExactOutput(
            address(_tokenIn), address(_tokenOut), _amountOut, _amountInMaximum, _poolFee
        );
    }

    /**
     * @notice Swap WETH to wstETH using Lido or Curve for ETH to stETH conversion, whichever offers a better rate.
     * @param _wethAmount The amount of WETH to swap.
     * @return wstEthReceived The amount of wstETH received from the swap.
     */
    function lidoSwapWethToWstEth(uint256 _wethAmount) external override returns (uint256 wstEthReceived) {
        // Unwrap WETH to ETH
        weth.withdraw(_wethAmount);

        // Check if Curve offers a better rate than Lido
        if (curvePool.get_dy(0, 1, _wethAmount) > _wethAmount) {
            // Swap ETH to stETH via Curve
            curvePool.exchange{value: _wethAmount}(0, 1, _wethAmount, _wethAmount);
        } else {
            // Swap ETH to stETH via Lido
            stEth.submit{value: _wethAmount}(address(0x00));
        }

        // Wrap stETH to wstETH
        uint256 stEthBalance = stEth.balanceOf(address(this));
        ERC20(address(stEth)).safeApprove(address(wstEth), stEthBalance);

        wstEthReceived = wstEth.wrap(stEthBalance);
    }

    /**
     * @notice Swap stETH to WETH on Curve.
     * @param _stEthAmount The amount of stETH to swap.
     * @param _wethAmountOutMin The minimum amount of WETH to receive.
     * @return wethReceived The amount of WETH received from the swap.
     */
    function curveSwapStEthToWeth(uint256 _stEthAmount, uint256 _wethAmountOutMin)
        external
        override
        returns (uint256 wethReceived)
    {
        // Approve stETH to Curve Pool
        ERC20(address(stEth)).safeApprove(address(curvePool), _stEthAmount);

        // Swap stETH to ETH via Curve
        wethReceived = curvePool.exchange(1, 0, _stEthAmount, _wethAmountOutMin);

        // Wrap ETH to WETH
        weth.deposit{value: address(this).balance}();
    }
}
