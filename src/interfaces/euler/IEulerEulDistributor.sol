// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

interface IEulerEulDistributor {
    function claim(address account, address token, uint256 claimable, bytes32[] calldata proof, address stake)
        external;
}
