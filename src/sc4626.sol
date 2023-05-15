// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {CallerNotAdmin, CallerNotKeeper, ZeroAddress, InvalidFlashLoanCaller} from "./errors/scErrors.sol";

abstract contract sc4626 is ERC4626, AccessControl {
    constructor(address _admin, address _keeper, ERC20 _asset, string memory _name, string memory _symbol)
        ERC4626(_asset, _name, _symbol)
    {
        if (_admin == address(0)) revert ZeroAddress();
        if (_keeper == address(0)) revert ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(KEEPER_ROLE, _keeper);
    }

    /// Role allowed to harvest/reinvest
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    bool public flashLoanInitiated;

    function _onlyAdmin() internal view {
        if (!hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) revert CallerNotAdmin();
    }

    function _onlyKeeper() internal view {
        if (!hasRole(KEEPER_ROLE, msg.sender)) revert CallerNotKeeper();
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
