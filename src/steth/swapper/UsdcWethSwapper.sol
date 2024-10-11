// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {ISinglePairSwapper} from "./../swapper/ISinglePairSwapper.sol";
import {SwapperLib} from "src/lib/SwapperLib.sol";
import {UniversalSwapper} from "./UniversalSwapper.sol";

/**
 * @title UsdcWethSwapper
 * @notice Contract facilitating swaps between USDC and WETH.
 */
contract UsdcWethSwapper is ISinglePairSwapper, UniversalSwapper {
    /// @notice The address of the asset token (USDC).
    address public constant override asset = address(C.USDC);

    /// @notice The address of the target token (WETH).
    address public constant override targetToken = address(C.WETH);

    /// @notice The fee tier of the Uniswap V3 pool.
    uint24 public constant POOL_FEE = 500;

    /**
     * @notice Swap WETH for USDC.
     * @param _wethAmount The amount of WETH to swap.
     * @param _usdcAmountOutMin The minimum amount of USDC to receive.
     * @return usdcReceived The amount of USDC received from the swap.
     */
    function swapTargetTokenForAsset(uint256 _wethAmount, uint256 _usdcAmountOutMin)
        external
        override
        returns (uint256 usdcReceived)
    {
        usdcReceived = SwapperLib._uniswapSwapExactInput(targetToken, asset, _wethAmount, _usdcAmountOutMin, POOL_FEE);
    }

    /**
     * @notice Swap USDC for an exact amount of WETH.
     * @param _wethAmountOut The exact amount of WETH desired.
     * @return usdcSpent The amount of USDC spent to receive `_wethAmountOut` of WETH.
     */
    function swapAssetForExactTargetToken(uint256 _wethAmountOut) external override returns (uint256 usdcSpent) {
        uint256 usdcBalance = ERC20(asset).balanceOf(address(this));

        usdcSpent = SwapperLib._uniswapSwapExactOutput(asset, targetToken, _wethAmountOut, usdcBalance, POOL_FEE);
    }
}
