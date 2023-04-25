// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

contract MintableERC20 is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    bool public initialized;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) ERC20(_name, _symbol, _decimals) {}

    function initialize(address _minter) external {
        require(!initialized);
        _grantRole(MINTER_ROLE, _minter);
        initialized = true;
    }

    function mint(address _account, uint256 _amount) external onlyRole(MINTER_ROLE) {
        _mint(_account, _amount);
    }
}
