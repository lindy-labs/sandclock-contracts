// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {ISinglePairSwapper} from "./../swapper/ISinglePairSwapper.sol";
import {SwapperLib} from "./SwapperLib.sol";
import {UniversalSwapper} from "./UniversalSwapper.sol";

contract WbtcWethSwapper is ISinglePairSwapper, UniversalSwapper {
    address public constant override asset = address(C.WBTC);
    address public constant override targetToken = address(C.WETH);
    uint24 public constant POOL_FEE = 500;

    function swapTargetTokenForAsset(uint256 _wethAmount, uint256 _wbtcAmountOutMin)
        external
        override
        returns (uint256)
    {
        return SwapperLib._uniswapSwapExactInput(targetToken, asset, _wethAmount, _wbtcAmountOutMin, POOL_FEE);
    }

    function swapAssetForExactTargetToken(uint256 _wethAmountOut) external override returns (uint256 wbtcSpent) {
        uint256 wbtcBalance = ERC20(asset).balanceOf(address(this));

        wbtcSpent = SwapperLib._uniswapSwapExactOutput(asset, targetToken, _wethAmountOut, wbtcBalance, POOL_FEE);
    }
}
