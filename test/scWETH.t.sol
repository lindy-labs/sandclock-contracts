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
import {IEulerDToken} from "../src/interfaces/euler/IEulerDToken.sol";
import {IEulerEToken} from "../src/interfaces/euler/IEulerEToken.sol";
import {IMarkets} from "../src/interfaces/euler/IMarkets.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";

contract scWETHTest is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;
    uint256 constant ethWstEthMaxLtv = 0.7735e18;
    uint256 constant slippageTolerance = 0.999e18;
    uint256 constant flashLoanLtv = 0.5e18;

    // dummy users
    address constant alice = address(0x06);

    Vault vault;
    uint256 initAmount = 100e18;

    address EULER;
    WETH weth;
    ILido stEth;
    IwstETH wstEth;
    IEulerEToken eTokenWstEth;
    IEulerDToken dTokenWeth;
    IMarkets markets;
    ICurvePool curvePool;

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(16643381);

        vault = new Vault(
            address(this),
            ethWstEthMaxLtv,
            flashLoanLtv,
            slippageTolerance
        );

        // set vault eth balance to zero
        vm.deal(address(vault), 0);

        weth = vault.weth();
        stEth = vault.stEth();
        wstEth = vault.wstETH();

        eTokenWstEth = vault.eToken();
        dTokenWeth = vault.dToken();
        markets = vault.markets();
        EULER = vault.EULER();
        curvePool = vault.curvePool();

        wstEth.approve(EULER, type(uint256).max);
        weth.approve(EULER, type(uint256).max);
        // Enter the euler collateral market (collateral's address, *not* the eToken address) ,
        markets.enterMarket(0, address(wstEth));
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

    function testWithdrawalAmounts() public {
        uint256 depositAmount1 = 100e18;
        uint256 depositAmount2 = 200e18;
        uint256 shares1 = depositToVault(address(this), depositAmount1);
        uint256 shares2 = depositToVault(alice, depositAmount2);

        vault.depositIntoStrategy();

        vault.redeem(shares1 / 2, address(this), address(this));
        assertRelApproxEq(weth.balanceOf(address(this)), depositAmount1 / 2, 0.01e18);

        vm.prank(alice);
        vault.redeem(shares2 / 2, alice, alice);
        assertRelApproxEq(weth.balanceOf(alice), depositAmount2 / 2, 0.01e18);

        console.log(weth.balanceOf(address(vault)));

        vault.redeem(shares1 / 2, address(this), address(this));
        assertRelApproxEq(weth.balanceOf(address(this)), depositAmount1, 0.01e18);

        vm.prank(alice);
        vault.redeem(shares2 / 2, alice, alice);
        assertRelApproxEq(weth.balanceOf(alice), depositAmount2, 0.01e18);
    }

    function testLeverageUp() public {
        uint256 depositAmount = 100e18;
        depositToVault(address(this), depositAmount);
        vault.depositIntoStrategy();
        vault.changeLeverage(0.76e18);
        assertApproxEqRel(vault.getLtv(), 0.76e18, 0.01e18, "leverage up failed");

        vault.changeLeverage(0.5e18);
        assertApproxEqRel(vault.getLtv(), 0.5e18, 0.01e18, "leverage up failed");
    }

    function depositToVault(address user, uint256 amount) public returns (uint256 shares) {
        vm.deal(user, amount);
        vm.startPrank(user);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
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

    // function testWithdrawAllToVault() public {
    //     // console.log("before deposit", weth.balanceOf(address(vault)));
    //     uint256 depositAmount = 5e18;

    //     vault.deposit(depositAmount, address(this));
    //     // console.log("after deposit", weth.balanceOf(address(vault)));

    //     // deposit into strategy
    //     vault.depositIntoStrategy();

    //     console.log("totalAssets", vault.totalAssets());

    //     // console.log("before withdraw", weth.balanceOf(address(vault)));

    //     // withdraw from strategy
    //     vault.withdrawToVault(depositAmount);

    //     // console.log("after withdraw", weth.balanceOf(address(vault)));
    //     console.log("totalAssets", weth.balanceOf(address(vault)));

    //     assertEq(vault.totalCollateralSupplied(), 0, "collateral not zero");
    //     assertEq(vault.totalDebt(), 0, "debt not zero");
    //     // stEth balance must be zero
    //     assertEq(stEth.balanceOf(address(vault)), 0, "stEth not zero");
    //     // wstEth balance must be zero
    //     assertEq(wstEth.balanceOf(address(vault)), 0, "wstEth not zero");
    //     // weth balance must be zero
    //     // assertEq(weth.balanceOf(address(vault)), 0, "weth not zero");
    //     // eth balance must be zero
    //     assertEq(address(vault).balance, 0, "eth not zero");
    // }

    // function testEulerBorrowTax() public {
    //     uint256 depositAmount = initAmount;
    //     topUpWstEth(depositAmount, address(this));
    //     vm.deal(address(this), 0);
    //     // dont take a flash loan

    //     // just deposit wstEth
    //     eTokenWstEth.deposit(0, depositAmount);

    //     console.log(wstEth.balanceOf(address(this)));

    //     console.log(weth.balanceOf(address(this)));
    //     // borrow eth
    //     dTokenWeth.borrow(0, (depositAmount * 5000) / 10000);
    //     // console.log(weth.balanceOf(address(this)));

    //     // // repay eth
    //     // dTokenWeth.repay(0, depositAmount / 2);

    //     // // withdraw wstEth
    //     // eTokenWstEth.withdraw(0, type(uint256).max);

    //     // console.log(wstEth.balanceOf(address(this)));
    // }

    // function testUnwrapAndExchange() public {
    //     uint256 depositAmount = 5e18;
    //     vm.deal(address(this), depositAmount);

    //     stEth.submit{value: depositAmount}(address(0x00));
    //     stEth.approve(address(wstEth), type(uint256).max);
    //     wstEth.wrap(stEth.balanceOf(address(this)));

    //     // wstETh to stEth
    //     wstEth.unwrap(wstEth.balanceOf(address(this)));
    //     stEth.approve(address(curvePool), type(uint256).max);
    //     // stEth to eth
    //     curvePool.exchange(1, 0, stEth.balanceOf(address(this)), 1);

    //     console.log("difference", depositAmount - address(this).balance);
    // }

    function topUpWstEth(uint256 amount, address to) internal {
        vm.prank(0x10CD5fbe1b404B7E19Ef964B63939907bdaf42E2);
        wstEth.transfer(to, amount);
    }

    receive() external payable {}
}
