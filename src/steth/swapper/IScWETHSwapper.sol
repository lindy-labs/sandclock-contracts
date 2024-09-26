// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "./ISwapper.sol";

/**
 * @title IScWETHSwapper
 * @notice Interface for a swapper handling stETH, wstETH, and WETH swaps.
 */
interface IScWETHSwapper is ISwapper {
    /**
     * @notice Swaps stETH to WETH using Curve.
     * @param _stEthAmount The amount of stETH to swap.
     * @param _wethAmountOutMin The minimum amount of WETH to receive.
     * @return wethReceived The amount of WETH received from the swap.
     */
    function curveSwapStEthToWeth(uint256 _stEthAmount, uint256 _wethAmountOutMin)
        external
        returns (uint256 wethReceived);

    /**
     * @notice Swaps WETH to wstETH using Lido or Curve.
     * @param _wethAmount The amount of WETH to swap.
     * @return wstEthReceived The amount of wstETH received from the swap.
     */
    function lidoSwapWethToWstEth(uint256 _wethAmount) external returns (uint256 wstEthReceived);
}
