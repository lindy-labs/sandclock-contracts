// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IERC4626} from "lib/forge-std/src/interfaces/IERC4626.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ISinglePairPriceConverter} from "./ISinglePairPriceConverter.sol";
import {AggregatorV3Interface} from "../../interfaces/chainlink/AggregatorV3Interface.sol";
import {Constants as C} from "../../lib/Constants.sol";

/**
 * @title DaiWethPriceConverter
 * @notice Contract for price conversion between DAI/USDS and WETH.
 */
contract DaiWethPriceConverter is ISinglePairPriceConverter {
    using FixedPointMathLib for uint256;

    /// @notice The address of the asset token (sDAI).
    address public constant override asset = C.DAI;

    /// @notice The address of the target token (WETH).
    address public constant override targetToken = C.WETH;

    /// @notice Chainlink price feed for DAI to ETH conversion.
    AggregatorV3Interface public constant DAI_ETH_PRICE_FEED = AggregatorV3Interface(C.CHAINLINK_DAI_ETH_PRICE_FEED);

    /**
     * @notice Converts an amount of WETH to the equivalent amount of DAI.
     * @param _ethAmount The amount of WETH to convert.
     * @return The equivalent amount of DAI.
     */
    function targetTokenToAsset(uint256 _ethAmount) external view override returns (uint256) {
        return _ethToDai(_ethAmount);
    }

    /**
     * @notice Converts an amount of DAI to the equivalent amount of WETH.
     * @param _daiAmount The amount of DAI to convert.
     * @return The equivalent amount of WETH.
     */
    function assetToTargetToken(uint256 _daiAmount) external view override returns (uint256) {
        return _daiToEth(_daiAmount);
    }

    /**
     * @notice Internal function to convert ETH to DAI.
     * @param _ethAmount The amount of ETH to convert.
     * @return The equivalent amount of DAI.
     */
    function _ethToDai(uint256 _ethAmount) internal view returns (uint256) {
        return _ethAmount.divWadDown(_daiPriceInEth());
    }

    /**
     * @notice Internal function to convert DAI to ETH.
     * @param _daiAmount The amount of DAI to convert.
     * @return The equivalent amount of ETH.
     */
    function _daiToEth(uint256 _daiAmount) internal view returns (uint256) {
        return _daiAmount.mulWadDown(_daiPriceInEth());
    }

    /**
     * @notice Internal function to get the DAI price in ETH from Chainlink.
     * @return The price of DAI in ETH.
     */
    function _daiPriceInEth() internal view returns (uint256) {
        (, int256 daiPriceInEth,,,) = DAI_ETH_PRICE_FEED.latestRoundData();

        return uint256(daiPriceInEth);
    }
}
