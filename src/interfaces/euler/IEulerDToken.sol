// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

interface IEulerDToken {
    function flashLoan(uint256 amount, bytes calldata data) external;

    /// @notice Transfer underlying tokens from the Euler pool to the sender, and increase sender's dTokens
    /// @param subAccountId 0 for primary, 1-255 for a sub-account
    /// @param amount In underlying units (use max uint256 for all available tokens)
    function borrow(uint256 subAccountId, uint256 amount) external;

    /// @notice Transfer underlying tokens from the sender to the Euler pool, and decrease sender's dTokens
    /// @param subAccountId 0 for primary, 1-255 for a sub-account
    /// @param amount In underlying units (use max uint256 for full debt owed)
    function repay(uint256 subAccountId, uint256 amount) external;

    /// @notice Debt owed by a particular account, in underlying units
    function balanceOf(address account) external view returns (uint256);
}
