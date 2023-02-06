// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {scUSDC as Vault} from "../src/steth/scUSDC.sol";

contract MockVault is Vault {
    constructor(MockERC20 _underlying) Vault(_underlying) {}
}

contract SandclockUSDCTest is DSTestPlus {
    using FixedPointMathLib for uint256;

    MockERC20 underlying;
    MockVault vault;

    function setUp() public {
        underlying = new MockERC20("Mock USDC", "USDC", 6);
        vault = new MockVault(underlying);
    }

    function testAtomicDepositWithdraw(uint256 amount) public {
        amount = bound(amount, 1e5, 1e27);
        underlying.mint(address(this), amount);
        underlying.approve(address(vault), amount);

        vault.deposit(amount, address(this));
        //vault.withdraw(amount, address(this), address(this));
    }

    function testFailDepositWithNotEnoughApproval(uint256 amount) public {
        underlying.mint(address(this), amount / 2);
        underlying.approve(address(vault), amount / 2);
        vault.deposit(amount, address(this));
    }

    function testFailWithdrawWithNotEnoughBalance(uint256 amount) public {
        underlying.mint(address(this), amount / 2);
        underlying.approve(address(vault), amount / 2);
        vault.deposit(amount / 2, address(this));
        vault.withdraw(amount, address(this), address(this));
    }

    function testFailRedeemWithNotEnoughBalance(uint256 amount) public {
        underlying.mint(address(this), amount / 2);
        underlying.approve(address(vault), amount / 2);
        vault.deposit(amount / 2, address(this));
        vault.redeem(amount, address(this), address(this));
    }

    function testFailWithdrawWithNoBalance(uint256 amount) public {
        if (amount == 0) amount = 1;
        vault.withdraw(amount, address(this), address(this));
    }

    function testFailRedeemWithNoBalance(uint256 amount) public {
        vault.redeem(amount, address(this), address(this));
    }

    function testFailDepositWithNoApproval(uint256 amount) public {
        vault.deposit(amount, address(this));
    }
}
