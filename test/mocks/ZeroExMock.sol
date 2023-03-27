// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/console.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../../src/interfaces/lido/ILido.sol";

contract ZeroExMock {
    using SafeTransferLib for ERC20;

    WETH weth;
    ILido stEth;

    constructor(address _weth, address _stEth) {
        weth = WETH(payable(_weth));
        stEth = ILido(_stEth);
    }

    function swap(uint256 amount) external payable {
        ERC20(address(weth)).safeTransferFrom(msg.sender, address(this), amount);
        weth.withdraw(amount);
        stEth.submit{value: amount}(address(0x00));
        ERC20(address(stEth)).safeTransfer(msg.sender, amount);
    }

    /// @dev Fallback for just receiving ether.
    receive() external payable {}
}
