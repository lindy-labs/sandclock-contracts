// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

import {PriceFeedZeroAddress, CallerNotAdmin} from "../errors/scErrors.sol";
import {Constants as C} from "../lib/Constants.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";

/**
 * @title Price Converter
 * @notice Contract for price conversion between WETH and USDC.
 */
contract PriceConverter is AccessControl {
    using FixedPointMathLib for uint256;

    event UsdcToEthPriceFeedUpdated(address indexed admin, address newPriceFeed);

    AggregatorV3Interface public usdcToEthPriceFeed = AggregatorV3Interface(C.CHAINLINK_USDC_ETH_PRICE_FEED);

    constructor(address _admin) {
        _setupRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function _onlyAdmin() internal view {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert CallerNotAdmin();
    }

    /**
     * @notice Set the chainlink price feed for USDC -> WETH.
     * @param _newPriceFeed The new price feed.
     */
    function setUsdcToEthPriceFeed(AggregatorV3Interface _newPriceFeed) external {
        _onlyAdmin();

        if (address(_newPriceFeed) == address(0)) revert PriceFeedZeroAddress();

        usdcToEthPriceFeed = _newPriceFeed;

        emit UsdcToEthPriceFeedUpdated(msg.sender, address(_newPriceFeed));
    }

    /**
     * @notice Returns the USDC fair value for the WETH amount provided.
     * @param _wethAmount The amount of WETH.
     */
    function getUsdcFromWeth(uint256 _wethAmount) public view returns (uint256) {
        (, int256 usdcPriceInWeth,,,) = usdcToEthPriceFeed.latestRoundData();

        return _wethAmount.divWadDown(uint256(usdcPriceInWeth) * C.WETH_USDC_DECIMALS_DIFF);
    }

    /**
     * @notice Returns the WETH fair value for the USDC amount provided.
     * @param _usdcAmount The amount of USDC.
     */
    function getWethFromUsdc(uint256 _usdcAmount) public view returns (uint256) {
        (, int256 usdcPriceInWeth,,,) = usdcToEthPriceFeed.latestRoundData();

        return (_usdcAmount * C.WETH_USDC_DECIMALS_DIFF).mulWadDown(uint256(usdcPriceInWeth));
    }
}
