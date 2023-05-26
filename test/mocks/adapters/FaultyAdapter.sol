// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {Constants as C} from "../../../src/lib/Constants.sol";
import {IAdapter} from "../../../src/steth/usdc-adapters/IAdapter.sol";

contract FaultyAdapter is IAdapter {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;

    uint8 public constant id = 0;

    // dummy address for token approvals
    address public constant protocol = address(0x123);

    function setApprovals() external override {
        ERC20(C.USDC).safeApprove(protocol, type(uint256).max);
        WETH(payable(C.WETH)).safeApprove(protocol, type(uint256).max);
    }

    function revokeApprovals() external override {
        ERC20(C.USDC).safeApprove(protocol, 0);
        WETH(payable(C.WETH)).safeApprove(protocol, 0);
    }

    function supply(uint256) external pure override {
        revert("not working");
    }

    function borrow(uint256) external pure override {
        revert("not working");
    }

    function repay(uint256) external pure override {
        revert("not working");
    }

    function withdraw(uint256) external pure override {
        revert("not working");
    }

    function claimRewards(bytes calldata _data) external view override {
        address caller = abi.decode(_data, (address));

        require(address(this) == caller, "invalid caller");
    }

    function getCollateral(address) external pure override returns (uint256) {
        revert("not working");
    }

    function getDebt(address) external pure override returns (uint256) {
        revert("not working");
    }
}
