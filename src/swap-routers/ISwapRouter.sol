// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

interface ISwapRouter {
    function from() external pure returns (address);
    function to() external pure returns (address);
    function swapDefault(uint256 amount, uint256 slippageTolerance) external;
    function swap0x(bytes calldata swapData, uint256 amount) external;
}
