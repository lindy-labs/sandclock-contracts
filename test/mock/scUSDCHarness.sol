// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {scUSDC} from "../../src/steth/scUSDC.sol";

import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {ISwapRouter} from "../../src/interfaces/uniswap/ISwapRouter.sol";

contract scUSDCHarness is scUSDC {
    constructor(address admin, ERC4626 wethVault, address mockSwapRouter) scUSDC(admin, wethVault) {
        swapRouter = ISwapRouter(mockSwapRouter);
        weth.approve(address(swapRouter), type(uint256).max);
    }
}
