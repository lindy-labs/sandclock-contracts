// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";

import {Constants as C} from "src/lib/Constants.sol";
import {SwapperLib} from "src/lib/SwapperLib.sol";
import {UniversalSwapper} from "./UniversalSwapper.sol";
import {ISinglePairSwapper} from "./../swapper/ISinglePairSwapper.sol";

/**
 * @title UsdtWethSwapper
 * @notice Contract facilitating swaps between USDT and WETH.
 */
contract UsdtWethSwapper is ISinglePairSwapper, UniversalSwapper {
    /// @notice The address of the asset token (USDT).
    address public constant override asset = address(C.USDT);

    /// @notice The address of the target token (WETH).
    address public constant override targetToken = address(C.WETH);

    /// @notice The fee tier of the Uniswap V3 pool.
    uint24 public constant POOL_FEE = 500;

    /**
     * @notice Swap WETH for USDT.
     * @param _wethAmount The amount of WETH to swap.
     * @param _usdtAmountOutMin The minimum amount of USDT to receive.
     * @return usdtReceived The amount of USDT received from the swap.
     */
    function swapTargetTokenForAsset(uint256 _wethAmount, uint256 _usdtAmountOutMin)
        external
        override
        returns (uint256 usdtReceived)
    {
        usdtReceived = SwapperLib._uniswapSwapExactInput(targetToken, asset, _wethAmount, _usdtAmountOutMin, POOL_FEE);
    }

    /**
     * @notice Swap USDT for an exact amount of WETH.
     * @param _wethAmountOut The exact amount of WETH desired.
     * @return usdtSpent The amount of USDT spent to receive `_wethAmountOut` of WETH.
     */
    function swapAssetForExactTargetToken(uint256 _wethAmountOut) external override returns (uint256 usdtSpent) {
        uint256 usdtBalance = ERC20(asset).balanceOf(address(this));

        usdtSpent = SwapperLib._uniswapSwapExactOutput(asset, targetToken, _wethAmountOut, usdtBalance, POOL_FEE);
    }
}
