// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {Constants as C} from "../../lib/Constants.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";

/**
 * @notice Interface for adapters that allow interactions with the lending protocols
 */
abstract contract IAdapter {
    ERC20 constant usdc = ERC20(C.USDC);
    WETH constant weth = WETH(payable(C.WETH));

    /**
     * @notice Returns the adapter's ID
     */
    function id() external virtual returns (uint8);

    /**
     * @notice Sets the necessary approvals (allowances) for interacting with the lending protocol
     */
    function setApprovals() external virtual;

    /**
     * @notice Removes the given approvals (allowances) for interacting with the lending protocol
     */
    function revokeApprovals() external virtual;

    /**
     * @notice Supplies the given amount of collateral to the lending protocol
     * @param amount The amount of collateral to supply
     */
    function supply(uint256 amount) external virtual;

    /**
     * @notice Borrows the given amount of debt from the lending protocol
     * @param amount The amount of debt to borrow
     */
    function borrow(uint256 amount) external virtual;

    /**
     * @notice Repays the given amount of debt to the lending protocol
     * @param amount The amount of debt to repay
     */
    function repay(uint256 amount) external virtual;

    /**
     * @notice Withdraws the given amount of collateral from the lending protocol
     * @param amount The amount of collateral to withdraw
     */
    function withdraw(uint256 amount) external virtual;

    /**
     * @notice Claims rewards awarded by the lending protocol
     * @param data Any data needed for the claim process
     */
    function claimRewards(bytes calldata data) external virtual;

    /**
     * @notice Returns the amount of collateral currently supplied to the lending protocol
     * @param account The account to check
     */
    function getCollateral(address account) external view virtual returns (uint256);

    /**
     * @notice Returns the amount of debt currently borrowed from the lending protocol
     * @param account The account to check
     */
    function getDebt(address account) external view virtual returns (uint256);
}
