// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ISinglePairPriceConverter} from "./ISinglePairPriceConverter.sol";
import {AggregatorV3Interface} from "../../interfaces/chainlink/AggregatorV3Interface.sol";
import {Constants as C} from "../../lib/Constants.sol";

/**
 * @title UsdtWethPriceConverter
 * @notice Contract for price conversion between USDT and WETH.
 */
contract UsdtWethPriceConverter is ISinglePairPriceConverter {
    using FixedPointMathLib for uint256;

    /// @notice The address of the asset token (USDT).
    address public constant override asset = C.USDT;

    /// @notice The address of the target token (WETH).
    address public constant override targetToken = C.WETH;

    /// @notice Chainlink price feed for USDT to ETH conversion.
    AggregatorV3Interface public constant USDT_ETH_PRICE_FEED = AggregatorV3Interface(C.CHAINLINK_USDT_ETH_PRICE_FEED);

    /**
     * @notice Converts an amount of WETH to the equivalent amount of USDT.
     * @param _wethAmount The amount of WETH to convert.
     * @return usdtAmount The equivalent amount of USDT.
     */
    function targetTokenToAsset(uint256 _wethAmount) external view override returns (uint256 usdtAmount) {
        usdtAmount = _wethAmount.divWadDown(_usdtPriceInEth() * C.WETH_USDT_DECIMALS_DIFF);
    }

    /**
     * @notice Converts an amount of USDT to the equivalent amount of WETH.
     * @param _usdtAmount The amount of USDT to convert.
     * @return wethAmount The equivalent amount of WETH.
     */
    function assetToTargetToken(uint256 _usdtAmount) external view override returns (uint256 wethAmount) {
        wethAmount = (_usdtAmount * C.WETH_USDT_DECIMALS_DIFF).mulWadDown(_usdtPriceInEth());
    }

    /**
     * @notice Internal function to get the USDT price in ETH from Chainlink.
     * @return The price of USDT in ETH.
     */
    function _usdtPriceInEth() internal view returns (uint256) {
        (, int256 usdtPriceInEth,,,) = USDT_ETH_PRICE_FEED.latestRoundData();

        return uint256(usdtPriceInEth);
    }
}
