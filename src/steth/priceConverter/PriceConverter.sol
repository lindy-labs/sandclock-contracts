// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {ZeroAddress, CallerNotAdmin} from "../../errors/scErrors.sol";
import {Constants as C} from "../../lib/Constants.sol";
import {AggregatorV3Interface} from "../../interfaces/chainlink/AggregatorV3Interface.sol";
import {IwstETH} from "../../interfaces/lido/IwstETH.sol";
import {IScETHPriceConverter} from "./IScETHPriceConverter.sol";

/**
 * @title Price Converter
 * @notice Contract for price conversion between assets used by staking vaults.
 */
contract PriceConverter is IScETHPriceConverter, AccessControl {
    using FixedPointMathLib for uint256;

    /// @notice The wstETH token contract.
    IwstETH public constant wstETH = IwstETH(C.WSTETH);

    event UsdcToEthPriceFeedUpdated(address indexed admin, address newPriceFeed);
    event StEthToEthPriceFeedUpdated(address indexed admin, address newPriceFeed);

    /// @notice Chainlink price feed for USDC to ETH conversion.
    AggregatorV3Interface public usdcToEthPriceFeed = AggregatorV3Interface(C.CHAINLINK_USDC_ETH_PRICE_FEED);

    /// @notice Chainlink price feed for stETH to ETH conversion.
    AggregatorV3Interface public stEThToEthPriceFeed = AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED);

    constructor(address _admin) {
        _zeroAddressCheck(_admin);
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    /**
     * @notice Internal function to check if the caller has the admin role.
     * @dev Reverts with `CallerNotAdmin` if the caller is not an admin.
     */
    function _onlyAdmin() internal view {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert CallerNotAdmin();
    }

    /**
     * @notice Sets the Chainlink price feed for USDC to ETH conversion.
     * @param _newPriceFeed The address of the new price feed.
     */
    function setUsdcToEthPriceFeed(address _newPriceFeed) external {
        _onlyAdmin();
        _zeroAddressCheck(_newPriceFeed);

        usdcToEthPriceFeed = AggregatorV3Interface(_newPriceFeed);

        emit UsdcToEthPriceFeedUpdated(msg.sender, address(_newPriceFeed));
    }

    /**
     * @notice Sets the Chainlink price feed for stETH to ETH conversion.
     * @param _newPriceFeed The address of the new price feed.
     */
    function setStEThToEthPriceFeed(address _newPriceFeed) external {
        _onlyAdmin();
        _zeroAddressCheck(_newPriceFeed);

        stEThToEthPriceFeed = AggregatorV3Interface(_newPriceFeed);

        emit StEthToEthPriceFeedUpdated(msg.sender, address(_newPriceFeed));
    }

    /**
     * @notice Converts an amount of ETH to its equivalent in USDC.
     * @param _ethAmount The amount of ETH to convert.
     * @return The equivalent amount of USDC.
     */
    function ethToUsdc(uint256 _ethAmount) public view returns (uint256) {
        (, int256 usdcPriceInEth,,,) = usdcToEthPriceFeed.latestRoundData();

        return _ethAmount.divWadDown(uint256(usdcPriceInEth) * C.WETH_USDC_DECIMALS_DIFF);
    }

    /**
     * @notice Converts an amount of USDC to its equivalent in ETH.
     * @param _usdcAmount The amount of USDC to convert.
     * @return The equivalent amount of ETH.
     */
    function usdcToEth(uint256 _usdcAmount) public view returns (uint256) {
        (, int256 usdcPriceInEth,,,) = usdcToEthPriceFeed.latestRoundData();

        return (_usdcAmount * C.WETH_USDC_DECIMALS_DIFF).mulWadDown(uint256(usdcPriceInEth));
    }

    /**
     * @notice Converts an amount of ETH to its equivalent in wstETH.
     * @param ethAmount The amount of ETH to convert.
     * @return The equivalent amount of wstETH.
     */
    function ethToWstEth(uint256 ethAmount) public view override returns (uint256) {
        (, int256 price,,,) = stEThToEthPriceFeed.latestRoundData();

        uint256 stEthAmount = ethAmount.divWadDown(uint256(price));

        return wstETH.getWstETHByStETH(stEthAmount);
    }

    /**
     * @notice Converts an amount of stETH to its equivalent in ETH.
     * @param _stEthAmount The amount of stETH to convert.
     * @return The equivalent amount of ETH.
     */
    function stEthToEth(uint256 _stEthAmount) public view override returns (uint256) {
        (, int256 price,,,) = stEThToEthPriceFeed.latestRoundData();

        return _stEthAmount.mulWadDown(uint256(price));
    }

    /**
     * @notice Converts an amount of wstETH to its equivalent in ETH.
     * @param wstEthAmount The amount of wstETH to convert.
     * @return The equivalent amount of ETH.
     */
    function wstEthToEth(uint256 wstEthAmount) public view override returns (uint256) {
        // Convert wstETH to stETH using exchange rate
        uint256 stEthAmount = wstETH.getStETHByWstETH(wstEthAmount);

        return stEthToEth(stEthAmount);
    }

    function _zeroAddressCheck(address _address) internal pure {
        if (_address == address(0)) revert ZeroAddress();
    }
}
