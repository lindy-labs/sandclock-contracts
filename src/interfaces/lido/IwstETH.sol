// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

interface IwstETH is IERC20 {
    function wrap(uint256 _stETHAmount) external returns (uint256);
}
