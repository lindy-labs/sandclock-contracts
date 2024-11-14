// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {ISinglePairSwapper} from "../swapper/ISinglePairSwapper.sol";
import {SwapperLib} from "./SwapperLib.sol";
import {UniversalSwapper} from "./UniversalSwapper.sol";
import {IDaiUsds} from "../../interfaces/sky/IDaiUsds.sol";

contract UsdsWethSwapper is ISinglePairSwapper, UniversalSwapper {
    /// @notice The address of the asset token (USDS).
    address public constant override asset = address(C.USDS);

    /// @notice The address of the target token (WETH).
    address public constant override targetToken = address(C.WETH);

    /// @notice DAI token used as an intermediate token for swaps.
    ERC20 public constant dai = ERC20(C.DAI);

    /// @notice The Dai - USDS converter contract from sky
    IDaiUsds public constant converter = IDaiUsds(C.DAI_USDS_CONVERTER);

    /// @notice Encoded swap path from WETH to DAI.
    bytes public constant swapPath = abi.encodePacked(targetToken, uint24(500), C.USDC, uint24(100), dai);

    /**
     * @notice Swap WETH for USDS.
     * @param _wethAmount The amount of WETH to swap.
     * @param _usdsAmountOutMin The minimum amount of USDS to receive.
     * @return usdsReceived The amount of USDS received from the swap.
     */
    function swapTargetTokenForAsset(uint256 _wethAmount, uint256 _usdsAmountOutMin)
        external
        override
        returns (uint256 usdsReceived)
    {
        // swap weth to dai
        usdsReceived = SwapperLib._uniswapSwapExactInputMultihop(targetToken, _wethAmount, _usdsAmountOutMin, swapPath);

        // swap dai to usds
        converter.daiToUsds(address(this), usdsReceived);
    }

    /**
     * @notice Swap USDS for an exact amount of WETH.
     * @param _wethAmountOut The exact amount of WETH desired.
     * @return usdsSpent The amount of USDS spent to receive `_wethAmountOut` of WETH.
     */
    function swapAssetForExactTargetToken(uint256 _wethAmountOut) external override returns (uint256 usdsSpent) {
        // convert all USDS to DAI
        uint256 usdsBalance = ERC20(asset).balanceOf(address(this));
        converter.usdsToDai(address(this), usdsBalance);

        // Swap DAI for exact amount of WETH
        usdsSpent = SwapperLib._uniswapSwapExactOutputMultihop(address(dai), _wethAmountOut, usdsBalance, swapPath);

        // convert remaining DAI back to USDS
        converter.daiToUsds(address(this), usdsBalance - usdsSpent);
    }
}
