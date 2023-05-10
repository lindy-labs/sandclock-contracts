// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {
    TreasuryCannotBeZero,
    FeesTooHigh,
    CallerNotAdmin,
    CallerNotKeeper,
    ZeroAddress,
    InvalidFlashLoanCaller
} from "./errors/scErrors.sol";

abstract contract sc4626 is ERC4626, AccessControl {
    constructor(address _admin, address _keeper, ERC20 _asset, string memory _name, string memory _symbol)
        ERC4626(_asset, _name, _symbol)
    {
        if (_admin == address(0)) revert ZeroAddress();
        if (_keeper == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _keeper);

        treasury = _admin;
    }

    bool flashLoanInitiated;
    uint256 public performanceFee = 0.1e18;
    uint256 public floatPercentage = 0.01e18;
    uint256 public minimumFloatAmount = 1 ether;
    address public treasury;

    /// Role allowed to harvest/reinvest
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    event PerformanceFeeUpdated(address indexed user, uint256 newPerformanceFee);
    event FloatPercentageUpdated(address indexed user, uint256 newFloatPercentage);
    event FloatAmountUpdated(address indexed user, uint256 newFloatAmount);
    event TreasuryUpdated(address indexed user, address newTreasury);

    modifier onlyAdmin() {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert CallerNotAdmin();
        _;
    }

    modifier onlyKeeper() {
        if (!hasRole(KEEPER_ROLE, msg.sender)) revert CallerNotKeeper();
        _;
    }

    function setPerformanceFee(uint256 newPerformanceFee) external onlyAdmin {
        if (newPerformanceFee > 1e18) revert FeesTooHigh();
        performanceFee = newPerformanceFee;
        emit PerformanceFeeUpdated(msg.sender, newPerformanceFee);
    }

    function setFloatPercentage(uint256 newFloatPercentage) external onlyAdmin {
        require(newFloatPercentage <= 1e18, "float percentage too high");
        floatPercentage = newFloatPercentage;
        emit FloatPercentageUpdated(msg.sender, newFloatPercentage);
    }

    function setMinimumFloatAmount(uint256 newFloatAmount) external onlyAdmin {
        minimumFloatAmount = newFloatAmount;
        emit FloatAmountUpdated(msg.sender, newFloatAmount);
    }

    function setTreasury(address newTreasury) external onlyAdmin {
        if (newTreasury == address(0)) revert TreasuryCannotBeZero();
        treasury = newTreasury;
        emit TreasuryUpdated(msg.sender, newTreasury);
    }

    function _initiateFlashLoan() internal {
        flashLoanInitiated = true;
    }

    function _finalizeFlashLoan() internal {
        flashLoanInitiated = false;
    }

    function _isFlashLoanInitiated() internal view {
        if (!flashLoanInitiated) revert InvalidFlashLoanCaller();
    }
}
