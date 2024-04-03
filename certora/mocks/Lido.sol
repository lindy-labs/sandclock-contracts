// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;
import {ILido} from "src/interfaces/lido/ILido.sol";

contract Lido is ILido {
    function totalSupply() external view returns (uint256) {}
    function balanceOf(address account) external view returns (uint256) {}
    function transfer(address to, uint256 amount) external returns (bool) {}
    function allowance(address owner, address spender) external view returns (uint256) {}
    function approve(address spender, uint256 amount) external returns (bool) {}
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {}
    function submit(address _referral) external payable returns (uint256) {}
    function getTotalPooledEther() external view returns (uint256) {}
}
