// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {scUSDC} from "../src/steth/scUSDC.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IEulerDToken} from "../src/interfaces/euler/IEulerDToken.sol";
import {IEulerEToken} from "../src/interfaces/euler/IEulerEToken.sol";
import {IMarkets} from "../src/interfaces/euler/IMarkets.sol";
import {scWETH} from "../src/steth/scWETH.sol";

import {TestPlus} from "./utils/TestPlus.sol";

contract scUSDCTest is TestPlus {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;
    uint256 constant ethWstEthMaxLtv = 0.7735e18;
    uint256 constant slippageTolerance = 0.999e18;
    uint256 constant flashLoanLtv = 0.5e18;

    // dummy users
    address constant alice = address(0x06);

    scUSDC vault;
    scWETH wethVault;
    uint256 initAmount = 100e18;

    address EULER;
    WETH weth;
    ERC20 usdc;
    IEulerEToken eTokenWstEth;
    IEulerDToken dTokenWeth;
    IMarkets markets;

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(16643381);

        usdc = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

        wethVault = new scWETH(address(this));

        vault = new scUSDC(address(this), wethVault);

        // set vault eth balance to zero
        vm.deal(address(vault), 0);
    }

    /// #deposit ///

    function testFuzz_deposit(uint256 amount) public {
        amount = bound(amount, 1e2, 1e18);
        deal(address(usdc), alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);

        vault.deposit(amount, alice);

        vm.stopPrank();

        assertEq(vault.convertToAssets(vault.balanceOf(alice)), amount);
        // 1 share = 1 usdc
        assertEq(vault.balanceOf(alice), amount);
    }

    /// #rebalance ///

    function test_rebalance_DepositsUsdcAndBorrowsWethOnEuler() public {
        uint256 amount = 10000e6;
        deal(address(usdc), address(vault), amount);

        assertEq(vault.totalCollateralSupplied(), 0);
        assertEq(vault.totalDebt(), 0);

        vault.rebalance();

        assertEq(vault.totalCollateralSupplied(), 9899999999); // ~ 100e6 - 1
        assertEq(vault.totalDebt(), 3758780024415885000);
        assertEq(vault.usdcBalance(), 100e6);
        assertApproxEq(vault.totalAssets(), amount, 1); // account for rounding error
    }

    function test_rebalance_RespectsRequiredFloatAmount() public {
        uint256 amount = 10000e6;
        uint256 floatRequired = 100e6; // 1% as default
        deal(address(usdc), address(vault), amount);

        vault.rebalance();

        assertEq(vault.usdcBalance(), floatRequired);
        assertApproxEq(vault.totalCollateralSupplied(), amount - floatRequired, 1); // account for rounding error
    }

    function test_rebalance_RespectsTargetLtvPercentage() public {
        deal(address(usdc), address(vault), 10000e6);

        vault.rebalance();

        assertTrue(vault.getLtv() <= vault.targetLtv());
        assertTrue(vault.targetLtv() - vault.getLtv() < 0.001e18);
    }

    function test_getLtv_Returns0IfNoWethWasBorrowed() public {
        deal(address(usdc), address(vault), 10000e6);

        assertEq(vault.getLtv(), 0);
    }

    /// #applyNewTargetLtv ///

    function test_applyNewTargetLtv_changesLtvUp() public {
        deal(address(usdc), address(vault), 10000e6);

        vault.rebalance();

        uint256 oldTargetLtv = vault.targetLtv();
        uint256 newTargetLtv = oldTargetLtv + 0.1e18;

        vault.applyNewTargetLtv(newTargetLtv);

        assertEq(vault.targetLtv(), newTargetLtv);
        assertTrue(vault.getLtv() > oldTargetLtv);
        assertTrue(vault.getLtv() <= newTargetLtv);
    }

    function test_applyNewTargetLtv_changesLtvDown() public {
        deal(address(usdc), address(vault), 10000e6);

        vault.rebalance();

        uint256 oldTargetLtv = vault.targetLtv();
        uint256 newTargetLtv = oldTargetLtv - 0.1e18;

        vault.applyNewTargetLtv(newTargetLtv);

        assertEq(vault.targetLtv(), newTargetLtv);
        assertTrue(vault.getLtv() < oldTargetLtv);
        assertTrue(vault.getLtv() <= newTargetLtv);
    }

    function test_applyNewTargetLtv_FailsIfNewLtvIsTooHigh() public {
        deal(address(usdc), address(vault), 10000e6);

        uint256 tooHighLtv = vault.maxLtv() + 1;

        vm.expectRevert(scUSDC.InvalidUsdcWethTargetLtv.selector);
        vault.applyNewTargetLtv(tooHighLtv);
    }

    function test_applyNewTargetLtv_worksIfNewLtvIs0() public {
        deal(address(usdc), address(vault), 10000e6);

        vault.rebalance();

        assertTrue(vault.getLtv() > 0);

        vault.applyNewTargetLtv(0);

        assertEq(vault.getLtv(), 0);
        assertEq(vault.totalDebt(), 0);
    }

    /// #totalAssets ///

    function test_totalAssets_ReturnsTotalAssets() public {
        uint256 amount = 10000e6;
        deal(address(usdc), address(vault), amount);

        vault.rebalance();

        assertApproxEq(vault.totalAssets(), amount, 1);
    }

    function test_totalAssets_AccountsForProfitsMade() public {
        uint256 amount = 10000e6;
        deal(address(usdc), address(vault), amount);

        vault.rebalance();

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested * 2);

        // ~6.5% profit because of 65% target ltv
        uint256 expectedProfit = amount.mulWadDown(vault.targetLtv());

        assertApproxEqRel(vault.totalAssets(), amount + expectedProfit, 0.005e18);
    }
}
