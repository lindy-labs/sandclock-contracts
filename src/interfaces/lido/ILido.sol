// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

interface ILido is IERC20 {
    function submit(address _referral) external payable returns (uint256);
}
