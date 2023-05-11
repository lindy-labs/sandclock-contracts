// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {MockStabilityPool} from "./mocks/liquity/MockStabilityPool.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {MockLiquityPriceFeed} from "./mocks/liquity/MockLiquityPriceFeed.sol";
import {MockPriceFeed} from "./mocks/liquity/MockPriceFeed.sol";
import {Mock0x} from "./mocks/0x/Mock0x.sol";
import {scLiquity as Vault} from "../src/liquity/scLiquity.sol";

contract MockVault is Vault {
    constructor(
        address _admin,
        address _keeper,
        MockERC20 _lusd,
        MockStabilityPool _stabilityPool,
        MockPriceFeed _priceFeed,
        MockERC20 _lqty,
        address _xrouter
    ) Vault(_admin, _keeper, _lusd) {
        stabilityPool = _stabilityPool;
        lusd2eth = _priceFeed;
        lqty = _lqty;
        xrouter = _xrouter;
        asset.approve(address(stabilityPool), type(uint256).max);
    }
}

contract SandclockLUSDTest is DSTestPlus {
    using FixedPointMathLib for uint256;

    MockERC20 underlying;
    MockERC20 lqty;
    Mock0x xrouter;
    MockVault vault;
    MockStabilityPool stabilityPool;
    MockLiquityPriceFeed priceFeed;
    MockPriceFeed lusd2eth;

    function setUp() public {
        underlying = new MockERC20("Mock LUSD", "LUSD", 18);
        lqty = new MockERC20("Mock LQTY", "LQTY", 18);
        xrouter = new Mock0x();
        priceFeed = new MockLiquityPriceFeed();
        stabilityPool = new MockStabilityPool(address(underlying), address(lqty), address(priceFeed));
        lusd2eth = new MockPriceFeed();
        lusd2eth.setPrice(935490589304841);
        vault = new MockVault(address(this), address(this), underlying, stabilityPool, lusd2eth, lqty, address(xrouter));
        vault.grantRole(vault.KEEPER_ROLE(), address(this));
    }

    function testAtomicDepositWithdraw(uint256 amount) public {
        amount = bound(amount, 1e5, 1e27);
        underlying.mint(address(this), amount);
        underlying.approve(address(vault), amount);

        uint256 preDepositBal = underlying.balanceOf(address(this));

        vault.deposit(amount, address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.totalInvested(), amount - amount.mulWadDown(vault.floatPercentage()));
        assertEq(vault.totalAssets(), amount);
        assertEq(vault.balanceOf(address(this)), amount);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), amount);
        assertEq(underlying.balanceOf(address(this)), preDepositBal - amount);

        vault.withdraw(amount, address(this), address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.totalInvested(), 0);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), 0);
        assertEq(underlying.balanceOf(address(this)), preDepositBal);
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

    function testDepositIntoStrategy(uint256 amount) public {
        underlying.mint(address(vault), amount);
        assertEq(underlying.balanceOf(address(vault)), amount);
        vault.depositIntoStrategy();
        assertEq(vault.totalAssets(), amount);
        uint256 targetFloat = amount.mulWadDown(vault.floatPercentage());
        assertEq(underlying.balanceOf(address(vault)), targetFloat);
        assertEq(stabilityPool.getCompoundedLUSDDeposit(address(vault)), amount - targetFloat);
        vault.depositIntoStrategy(); // test idempotency of this operation
        assertEq(underlying.balanceOf(address(vault)), targetFloat);
        assertEq(stabilityPool.getCompoundedLUSDDeposit(address(vault)), amount - targetFloat);
    }

    function testHarvest(uint256 lqtyAmount, uint256 ethAmount) public {
        uint256 totalAssetsBefore = vault.totalAssets();
        lqty.mint(address(stabilityPool), lqtyAmount);
        hevm.deal(address(stabilityPool), ethAmount);
        bytes memory lqtySwapData = abi.encode(address(lqty), address(underlying), lqtyAmount);
        bytes memory ethSwapData = abi.encode(address(0), address(underlying), ethAmount);
        vault.harvest(lqtyAmount, lqtySwapData, ethAmount, ethSwapData);
        uint256 totalAssetsAfter = vault.totalAssets();
        assertEq(totalAssetsBefore + lqtyAmount + ethAmount, totalAssetsAfter);
    }

    function testFailHarvest(uint256 lqtyAmount, uint256 ethAmount) public {
        lqty.mint(address(stabilityPool), lqtyAmount);
        hevm.deal(address(stabilityPool), ethAmount);
        bytes memory lqtySwapData = abi.encode(address(lqty), address(underlying), lqtyAmount);
        bytes memory ethSwapData = abi.encode(address(0), address(underlying), ethAmount);
        xrouter.setShouldFailOnSwap(true);
        vault.harvest(lqtyAmount, lqtySwapData, ethAmount, ethSwapData);
    }

    function testWithdrawNoMoreThanFloat(uint256 amount) public {
        underlying.mint(address(this), amount);
        underlying.approve(address(vault), amount);

        uint256 preDepositBal = underlying.balanceOf(address(this));
        vault.deposit(amount, address(this));
        vault.withdraw(0, address(this), address(this));

        assertEq(underlying.balanceOf(address(this)), preDepositBal);
    }
}
