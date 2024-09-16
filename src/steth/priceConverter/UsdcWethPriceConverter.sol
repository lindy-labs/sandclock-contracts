// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ISinglePairPriceConverter} from "./ISinglePairPriceConverter.sol";
import {AggregatorV3Interface} from "../../interfaces/chainlink/AggregatorV3Interface.sol";
import {Constants as C} from "../../lib/Constants.sol";

/**
 * @title UsdcWethPriceConverter
 * @notice Contract for price conversion between USDC and WETH.
 */
contract UsdcWethPriceConverter is ISinglePairPriceConverter {
    using FixedPointMathLib for uint256;

    /// @notice The address of the asset token (USDC).
    address public constant override asset = C.USDC;

    /// @notice The address of the target token (WETH).
    address public constant override targetToken = C.WETH;

    /// @notice Chainlink price feed for USDC to ETH conversion.
    AggregatorV3Interface public constant usdcToEthPriceFeed = AggregatorV3Interface(C.CHAINLINK_USDC_ETH_PRICE_FEED);

    /**
     * @notice Converts an amount of WETH to the equivalent amount of USDC.
     * @param _wethAmount The amount of WETH to convert.
     * @return usdcAmount The equivalent amount of USDC.
     */
    function targetTokenToAsset(uint256 _wethAmount) external view override returns (uint256 usdcAmount) {
        usdcAmount = _wethAmount.divWadDown(_usdcPriceInEth() * C.WETH_USDC_DECIMALS_DIFF);
    }

    /**
     * @notice Converts an amount of USDC to the equivalent amount of WETH.
     * @param _usdcAmount The amount of USDC to convert.
     * @return wethAmount The equivalent amount of WETH.
     */
    function assetToTargetToken(uint256 _usdcAmount) external view override returns (uint256 wethAmount) {
        wethAmount = (_usdcAmount * C.WETH_USDC_DECIMALS_DIFF).mulWadDown(_usdcPriceInEth());
    }

    /**
     * @notice Internal function to get the USDC price in ETH from Chainlink.
     * @return The price of USDC in ETH.
     */
    function _usdcPriceInEth() internal view returns (uint256) {
        (, int256 usdcPriceInEth,,,) = usdcToEthPriceFeed.latestRoundData();

        return uint256(usdcPriceInEth);
    }
}
