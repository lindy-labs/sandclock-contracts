// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {ICurvePool} from "../../../src/interfaces/curve/ICurvePool.sol";
import {MockStETH} from "../lido/MockStETH.sol";

contract MockCurvePool is ICurvePool {
    MockStETH public stEth;

    constructor(MockStETH _stEth) {
        stEth = _stEth;
    }

    function exchange(int128 i, int128, uint256 dx, uint256 min_dy) external payable override returns (uint256) {
        if (i == 0) {
            require(stEth.balanceOf(address(this)) >= min_dy + 0.01e18, "MockCurvePool: INSUFFICIENT_TOKEN_OUT_BALANCE");

            stEth.transfer(msg.sender, min_dy + 0.01e18);
        } else {
            require(stEth.allowance(msg.sender, address(this)) >= dx, "MockCurvePool: INSUFFICIENT_TOKEN_IN_ALLOWANCE");
            require(address(this).balance >= min_dy + 0.01e18, "MockCurvePool: INSUFFICIENT_ETH_BALANCE");

            stEth.transferFrom(msg.sender, address(this), dx);
            payable(msg.sender).transfer(min_dy + 0.01e18);
        }

        return min_dy + 0.01e18;
    }
}
