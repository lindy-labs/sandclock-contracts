// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

abstract contract sc4626 is ERC4626, AccessControl {
    constructor(address _admin, ERC20 _asset, string memory _name, string memory _symbol)
        ERC4626(_asset, _name, _symbol)
    {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _admin);

        treasury = _admin;
    }

    uint256 public performanceFee = 0.1e18;
    uint256 public floatPercentage = 0.01e18;
    address public treasury;

    /// Role allowed to harvest/reinvest
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    event PerformanceFeeUpdated(address indexed user, uint256 newPerformanceFee);
    event FloatPercentageUpdated(address indexed user, uint256 newFloatPercentage);
    event TreasuryUpdated(address indexed user, address newTreasury);

    function setPerformanceFee(uint256 newPerformanceFee) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newPerformanceFee <= 1e18, "fee too high");
        performanceFee = newPerformanceFee;
        emit PerformanceFeeUpdated(msg.sender, newPerformanceFee);
    }

    function setFloatPercentage(uint256 newFloatPercentage) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newFloatPercentage <= 1e18, "float percentage too high");
        floatPercentage = newFloatPercentage;
        emit FloatPercentageUpdated(msg.sender, newFloatPercentage);
    }

    function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newTreasury != address(0), "treasury cannot be zero");
        treasury = newTreasury;
        emit TreasuryUpdated(msg.sender, newTreasury);
    }

    function depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external {
        // Approve via permit.
        asset.permit(msg.sender, address(this), amount, deadline, v, r, s);

        // Deposit
        deposit(amount, msg.sender);
    }
}
