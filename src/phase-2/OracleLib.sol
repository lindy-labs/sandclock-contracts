// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import "forge-std/console.sol";

import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {scWETHv2} from "./scWETHv2.sol";
import {IAdapter} from "../scWeth-adapters/IAdapter.sol";

import {CallerNotAdmin, ZeroAddress} from "../errors/scErrors.sol";

// TODO: this contract can be merged with the PriceConverter.sol since the purpose of both is the same
contract OracleLib is AccessControl {
    using FixedPointMathLib for uint256;

    // Chainlink pricefeed (stETH -> ETH)
    AggregatorV3Interface public stEThToEthPriceFeed;
    IwstETH immutable wstETH;
    address immutable weth;

    constructor(AggregatorV3Interface _stEThToEthPriceFeed, address _wstETH, address _weth, address _admin) {
        stEThToEthPriceFeed = _stEThToEthPriceFeed;
        wstETH = IwstETH(_wstETH);
        weth = _weth;

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function _onlyAdmin() internal view {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert CallerNotAdmin();
    }

    //////////////////////// ORACLE METHODS ///////////////////////////////
    function ethToWstEth(uint256 ethAmount) public view returns (uint256 wstEthAmount) {
        if (ethAmount > 0) {
            (, int256 price,,,) = stEThToEthPriceFeed.latestRoundData();

            // eth to stEth
            uint256 stEthAmount = ethAmount.divWadDown(uint256(price));

            // stEth to wstEth
            wstEthAmount = wstETH.getWstETHByStETH(stEthAmount);
        }
    }

    function stEthToEth(uint256 stEthAmount) public view returns (uint256 ethAmount) {
        if (stEthAmount > 0) {
            // stEth to eth
            (, int256 price,,,) = stEThToEthPriceFeed.latestRoundData();
            ethAmount = stEthAmount.mulWadDown(uint256(price));
        }
    }

    function wstEthToEth(uint256 wstEthAmount) public view returns (uint256 ethAmount) {
        // wstETh to stEth using exchangeRate
        uint256 stEthAmount = wstETH.getStETHByWstETH(wstEthAmount);
        ethAmount = stEthToEth(stEthAmount);
    }

    /// @notice set stEThToEthPriceFeed address
    /// @param newAddress the new address of the stEThToEthPriceFeed
    function setStEThToEthPriceFeed(address newAddress) external {
        _onlyAdmin();
        if (newAddress == address(0)) revert ZeroAddress();
        stEThToEthPriceFeed = AggregatorV3Interface(newAddress);
    }
}
