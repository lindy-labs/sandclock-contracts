// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {ISinglePairSwapper} from "../swapper/ISinglePairSwapper.sol";
import {SwapperLib} from "./SwapperLib.sol";
import {UniversalSwapper} from "./UniversalSwapper.sol";

/**
 * @title SDaiWethSwapper
 * @notice Contract facilitating swaps between sDAI and WETH.
 * @dev Uses DAI as an intermediate token for swaps.
 */
contract SDaiWethSwapper is ISinglePairSwapper, UniversalSwapper {
    /// @notice The address of the asset token (sDAI).
    address public constant override asset = address(C.SDAI);

    /// @notice The address of the target token (WETH).
    address public constant override targetToken = address(C.WETH);

    /// @notice DAI token used as an intermediate token for swaps.
    ERC20 public constant dai = ERC20(C.DAI);

    /// @notice Encoded swap path from WETH to DAI.
    bytes public constant swapPath = abi.encodePacked(targetToken, uint24(500), C.USDC, uint24(100), dai);

    /**
     * @notice Swap WETH for sDAI.
     * @param _wethAmount The amount of WETH to swap.
     * @param _sDaiAmountOutMin The minimum amount of sDAI to receive.
     * @return sDaiReceived The amount of sDAI received from the swap.
     */
    function swapTargetTokenForAsset(uint256 _wethAmount, uint256 _sDaiAmountOutMin)
        external
        override
        returns (uint256 sDaiReceived)
    {
        uint256 daiAmountOutMin = ERC4626(asset).convertToAssets(_sDaiAmountOutMin);

        uint256 daiReceived =
            SwapperLib._uniswapSwapExactInputMultihop(targetToken, _wethAmount, daiAmountOutMin, swapPath);

        sDaiReceived = ERC4626(asset).deposit(daiReceived, address(this));
    }

    /**
     * @notice Swap sDAI for an exact amount of WETH.
     * @param _wethAmountOut The exact amount of WETH desired.
     * @return sDaiSpent The amount of sDAI spent to receive `_wethAmountOut` of WETH.
     */
    function swapAssetForExactTargetToken(uint256 _wethAmountOut) external override returns (uint256 sDaiSpent) {
        // Redeem all sDAI to DAI
        uint256 sDaiBalance = ERC20(asset).balanceOf(address(this));

        uint256 daiBalance = ERC4626(asset).redeem(sDaiBalance, address(this), address(this));

        // Swap DAI for exact amount of WETH
        uint256 daiSpent =
            SwapperLib._uniswapSwapExactOutputMultihop(address(dai), _wethAmountOut, daiBalance, swapPath);

        // Deposit remaining DAI back to sDAI
        uint256 remainingSDai = ERC4626(asset).deposit(daiBalance - daiSpent, address(this));

        sDaiSpent = sDaiBalance - remainingSDai;
    }
}
