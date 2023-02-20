// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {scWETH as Vault} from "../src/steth/scWETH.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";

contract scWETHTest is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;
    uint256 constant ethWstEthMaxLtv = 0.7735e18;
    uint256 constant borrowPercentLtv = 0.99e18;
    uint256 constant slippageTolerance = 0.999e18;

    // dummy users
    address constant alice = address(0x06);

    Vault vault;
    WETH weth;
    ILido stEth;
    IwstETH wstEth;

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(16643381);

        vault = new Vault(
            address(this),
            ethWstEthMaxLtv,
            borrowPercentLtv,
            slippageTolerance
        );

        // set vault eth balance to zero
        vm.deal(address(vault), 0);

        weth = vault.weth();
        stEth = vault.stEth();
        wstEth = vault.wstETH();
    }

    function testAtomicDepositWithdraw(uint256 amount) public {
        amount = bound(amount, 1e5, 1e27);
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);

        uint256 preDepositBal = weth.balanceOf(address(this));

        vault.deposit(amount, address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.totalAssets(), amount);
        assertEq(vault.balanceOf(address(this)), amount);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), amount);
        assertEq(weth.balanceOf(address(this)), preDepositBal - amount);

        vault.withdraw(amount, address(this), address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), 0);
        assertEq(weth.balanceOf(address(this)), preDepositBal);
    }

    function testFailDepositWithNotEnoughApproval(uint256 amount) public {
        vm.deal(address(this), amount / 2);
        weth.deposit{value: amount / 2}();
        weth.approve(address(vault), amount / 2);
        vault.deposit(amount, address(this));
    }

    function testFailWithdrawWithNotEnoughBalance(uint256 amount) public {
        vm.deal(address(this), amount / 2);
        weth.deposit{value: amount / 2}();
        weth.approve(address(vault), amount / 2);
        vault.deposit(amount / 2, address(this));
        vault.withdraw(amount, address(this), address(this));
    }

    function testFailRedeemWithNotEnoughBalance(uint256 amount) public {
        vm.deal(address(this), amount / 2);
        weth.deposit{value: amount / 2}();
        weth.approve(address(vault), amount / 2);
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

    function testAtomicDepositInvestRedeem(uint256 amount) public {
        amount = bound(amount, 1e5, 1e21); //max ~$280m flashloan
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);

        uint256 preDepositBal = weth.balanceOf(address(this));

        uint256 shares = vault.deposit(amount, address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.totalAssets(), amount);
        assertEq(vault.balanceOf(address(this)), amount);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), amount);
        assertEq(weth.balanceOf(address(this)), preDepositBal - amount);

        vault.depositIntoStrategy();

        assertRelApproxEq(vault.totalAssets(), amount, 0.01e18);
        assertEq(vault.balanceOf(address(this)), amount);
        assertRelApproxEq(vault.convertToAssets(vault.balanceOf(address(this))), amount, 0.01e18);
        assertEq(weth.balanceOf(address(this)), preDepositBal - amount);

        vault.redeem(shares, address(this), address(this));

        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), 0);
        assertRelApproxEq(weth.balanceOf(address(this)), preDepositBal, 0.01e18);
    }

    function assertRelApproxEq(
        uint256 a,
        uint256 b,
        uint256 maxPercentDelta // An 18 decimal fixed point number, where 1e18 == 100%
    ) internal virtual {
        if (b == 0) return assertEq(a, b); // If the expected is 0, actual must be too.

        uint256 percentDelta = ((a > b ? a - b : b - a) * 1e18) / b;

        if (percentDelta > maxPercentDelta) {
            emit log("Error: a ~= b not satisfied [uint]");
            emit log_named_uint("    Expected", b);
            emit log_named_uint("      Actual", a);
            emit log_named_decimal_uint(" Max % Delta", maxPercentDelta, 18);
            emit log_named_decimal_uint("     % Delta", percentDelta, 18);
            fail();
        }
    }
}
