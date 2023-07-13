// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IProtocolFeesCollector {
    function getFlashLoanFeePercentage() external view returns (uint256);
    function setFlashLoanFeePercentage(uint256 newFlashLoanFeePercentage) external;
}
