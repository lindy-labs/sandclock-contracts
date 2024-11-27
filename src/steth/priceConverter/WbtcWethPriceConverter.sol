// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ISinglePairPriceConverter} from "./ISinglePairPriceConverter.sol";
import {AggregatorV3Interface} from "../../interfaces/chainlink/AggregatorV3Interface.sol";
import {Constants as C} from "../../lib/Constants.sol";

/**
 * @title WbtcWethPriceConverter
 * @notice Contract for price conversion between WBTC and WETH.
 */
contract WbtcWethPriceConverter is ISinglePairPriceConverter {
    using FixedPointMathLib for uint256;

    /// @notice The address of the asset token (WBTC).
    address public constant asset = C.WBTC;

    /// @notice The address of the target token (WETH).
    address public constant targetToken = C.WETH;

    /// @notice Chainlink price feed for WBTC to ETH conversion.
    AggregatorV3Interface public constant WBTC_ETH_PRICE_FEED = AggregatorV3Interface(C.CHAINLINK_WBTC_ETH_PRICE_FEED);

    /**
     * @notice Converts an amount of WETH to the equivalent amount of WBTC.
     * @param _wethAmount The amount of WETH to convert.
     * @return wbtcAmount The equivalent amount of WBTC.
     */
    function targetTokenToAsset(uint256 _wethAmount) external view override returns (uint256 wbtcAmount) {
        wbtcAmount = _wethAmount.divWadDown(_wbtcPriceInEth() * C.WETH_WBTC_DECIMALS_DIFF);
    }

    /**
     * @notice Converts an amount of WBTC to the equivalent amount of WETH.
     * @param _wbtcAmount The amount of WBTC to convert.
     * @return wethAmount The equivalent amount of WETH.
     */
    function assetToTargetToken(uint256 _wbtcAmount) external view override returns (uint256 wethAmount) {
        wethAmount = (_wbtcAmount * C.WETH_WBTC_DECIMALS_DIFF).mulWadDown(_wbtcPriceInEth());
    }

    /**
     * @notice Internal function to get the WBTC price in ETH from Chainlink.
     * @return The price of WBTC in ETH.
     */
    function _wbtcPriceInEth() internal view returns (uint256) {
        (, int256 wbtcPriceInEth,,,) = WBTC_ETH_PRICE_FEED.latestRoundData();

        return uint256(wbtcPriceInEth);
    }
}
