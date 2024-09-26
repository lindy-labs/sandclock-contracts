// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {IPriceConverter} from "./IPriceConverter.sol";

/**
 * @title IScETHPriceConverter
 * @notice Interface for price conversion functions involving ETH, stETH, and wstETH.
 */
interface IScETHPriceConverter is IPriceConverter {
    /**
     * @notice Converts an amount of ETH to the equivalent amount of wstETH.
     * @param ethAmount The amount of ETH to convert.
     * @return The equivalent amount of wstETH.
     */
    function ethToWstEth(uint256 ethAmount) external view returns (uint256);

    /**
     * @notice Converts an amount of stETH to the equivalent amount of ETH.
     * @param _stEthAmount The amount of stETH to convert.
     * @return The equivalent amount of ETH.
     */
    function stEthToEth(uint256 _stEthAmount) external view returns (uint256);

    /**
     * @notice Converts an amount of wstETH to the equivalent amount of ETH.
     * @param wstEthAmount The amount of wstETH to convert.
     * @return The equivalent amount of ETH.
     */
    function wstEthToEth(uint256 wstEthAmount) external view returns (uint256);
}
