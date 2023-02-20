// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
// import "forge-std/console2.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {IEulerDToken} from "../src/interfaces/euler/IEulerDToken.sol";
import {IEulerEToken} from "../src/interfaces/euler/IEulerEToken.sol";
import {IMarkets} from "../src/interfaces/euler/IMarkets.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";

contract scWETHTest is Test {
    using FixedPointMathLib for uint256;

    string MAINNET_RPC_URL = vm.envString("RPC_URL_MAINNET");
    uint256 mainnetFork;
    uint256 constant ethWstEthMaxLtv = 7735 * 1e14; // 0.7735
    uint256 constant borrowPercentLtv = 9900 * 1e14; // 0.95
    uint256 constant slippageTolerance = 1e16; // 0.1

    // dummy users
    address alice = address(0x06);

    uint256 initAmount = 100e18;

    address EULER;
    scWETH vault;
    WETH weth;
    ILido stEth;
    IwstETH wstEth;
    IEulerEToken eTokenWstEth;
    IEulerDToken dTokenWeth;
    IMarkets markets;
    ICurvePool curvePool;

    function setUp() public {
        vm.createFork(MAINNET_RPC_URL);
        vm.selectFork(mainnetFork);
        vm.rollFork(16642138);

        vault = new scWETH(
            address(this),
            ethWstEthMaxLtv,
            borrowPercentLtv,
            slippageTolerance
        );

        // set vault eth address to zero
        vm.deal(address(vault), 0);

        weth = vault.weth();
        stEth = vault.stEth();
        wstEth = vault.wstETH();
        eTokenWstEth = vault.eTokenwstETH();
        dTokenWeth = vault.dTokenWeth();
        markets = vault.markets();
        EULER = vault.EULER();
        curvePool = vault.curvePool();

        wstEth.approve(EULER, type(uint256).max);
        weth.approve(EULER, type(uint256).max);
        // Enter the euler collateral market (collateral's address, *not* the eToken address) ,
        markets.enterMarket(0, address(wstEth));

        // top up this and the other addresses with weth
        weth.deposit{value: initAmount * 2}();
        weth.transfer(alice, initAmount);

        // approvals
        weth.approve(address(vault), type(uint256).max);

        vm.prank(alice);
        weth.approve(address(vault), type(uint256).max);
    }

    // function testUserDeposit() public {
    //     uint256 depositAmount = 1e18;
    //     // user deposit must send weth from the user to the vault
    //     // and give out shares to the user

    //     vault.deposit(depositAmount, address(this));

    //     assertEq(weth.balanceOf(address(this)), initAmount - depositAmount);
    //     assertEq(weth.balanceOf(address(vault)), depositAmount);
    //     assertEq(vault.balanceOf(address(this)), depositAmount);

    //     vm.prank(alice);
    //     vault.deposit(depositAmount, alice);

    //     assertEq(weth.balanceOf(address(vault)), depositAmount * 2);
    //     assertEq(vault.balanceOf(alice), depositAmount);
    // }

    // function testDepositIntoStrategy() public {
    //     // taking all the weth into the vault and depositing into strategy by backend
    //     uint256 depositAmount = 100e18;
    //     vault.deposit(depositAmount, address(this));

    //     assertEq(weth.balanceOf(address(vault)), depositAmount);

    //     // deposit into strategy
    //     vault.depositIntoStrategy();

    //     assertEq(weth.balanceOf(address(vault)), 0);

    //     // console.log("leverage", vault.getLeverage());
    //     // console.log("collateral", vault.totalCollateralSupplied());
    //     // console.log("debt", vault.totalDebt());
    //     // console.log("totalAssets", vault.totalAssets());
    //     console.log("difference", depositAmount - vault.totalAssets());

    //     // vault.deposit(depositAmount, address(this));
    //     // // deposit into strategy
    //     // vault.depositIntoStrategy();
    //     // // console.log("leverage", vault.getLeverage());
    //     // // console.log("collateral", vault.totalCollateralSupplied());
    //     // // console.log("debt", vault.totalDebt());
    //     // // console.log("totalAssets", vault.totalAssets());
    //     // console.log("difference", depositAmount * 2 - vault.totalAssets());
    // }

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

    function testUnwrapAndExchange() public {
        uint256 depositAmount = 5e18;
        vm.deal(address(this), depositAmount);

        stEth.submit{value: depositAmount}(address(0x00));
        stEth.approve(address(wstEth), type(uint256).max);
        wstEth.wrap(stEth.balanceOf(address(this)));

        // wstETh to stEth
        wstEth.unwrap(wstEth.balanceOf(address(this)));
        stEth.approve(address(curvePool), type(uint256).max);
        // stEth to eth
        curvePool.exchange(1, 0, stEth.balanceOf(address(this)), 1);

        console.log("difference", depositAmount - address(this).balance);
    }

    function topUpWstEth(uint256 amount, address to) internal {
        vm.prank(0x10CD5fbe1b404B7E19Ef964B63939907bdaf42E2);
        wstEth.transfer(to, amount);
    }

    receive() external payable {}
}
