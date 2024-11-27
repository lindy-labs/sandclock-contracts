// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {ISinglePairSwapper} from "./../swapper/ISinglePairSwapper.sol";
import {SwapperLib} from "./SwapperLib.sol";
import {UniversalSwapper} from "./UniversalSwapper.sol";

/**
 * @title WbtcWethSwapper
 * @notice Contract facilitating swaps between WBTC and WETH.
 */
contract WbtcWethSwapper is ISinglePairSwapper, UniversalSwapper {
    /// @notice The address of the asset token (WBTC).
    address public constant override asset = address(C.WBTC);

    /// @notice The address of the target token (WETH).
    address public constant override targetToken = address(C.WETH);

    /// @notice The fee tier of the Uniswap V3 pool.
    uint24 public constant POOL_FEE = 500;

    /**
     * @notice Swap WETH for WBTC.
     * @param _wethAmount The amount of WETH to swap.
     * @param _wbtcAmountOutMin The minimum amount of WBTC to receive.
     * @return wbtcReceived The amount of WBTC received from the swap.
     */
    function swapTargetTokenForAsset(uint256 _wethAmount, uint256 _wbtcAmountOutMin)
        external
        override
        returns (uint256 wbtcReceived)
    {
        wbtcReceived = SwapperLib._uniswapSwapExactInput(targetToken, asset, _wethAmount, _wbtcAmountOutMin, POOL_FEE);
    }

    /**
     * @notice Swap WBTC for an exact amount of WETH.
     * @param _wethAmountOut The exact amount of WETH desired.
     * @return wbtcSpent The amount of WBTC spent to receive `_wethAmountOut` of WETH.
     */
    function swapAssetForExactTargetToken(uint256 _wethAmountOut) external override returns (uint256 wbtcSpent) {
        uint256 wbtcBalance = ERC20(asset).balanceOf(address(this));

        wbtcSpent = SwapperLib._uniswapSwapExactOutput(asset, targetToken, _wethAmountOut, wbtcBalance, POOL_FEE);
    }
}
