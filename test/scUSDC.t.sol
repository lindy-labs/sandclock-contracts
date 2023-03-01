// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

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

    /// #constructor ///

    function test_constructor() public {
        assertEq(address(vault.asset()), address(usdc));
        assertEq(address(vault.scWETH()), address(wethVault));

        // check approvals
        assertEq(usdc.allowance(address(vault), vault.EULER()), type(uint256).max, "usdc->euler appor");

        assertEq(weth.allowance(address(vault), vault.EULER()), type(uint256).max, "weth->euler allowance");
        assertEq(
            weth.allowance(address(vault), address(vault.swapRouter())), type(uint256).max, "weth->swapRouter allowance"
        );
        assertEq(weth.allowance(address(vault), address(vault.scWETH())), type(uint256).max, "weth->scWETH allowance");
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

        assertApproxEq(vault.totalCollateralSupplied(), amount.mulWadDown(0.99e18), 1); // - float
        assertEq(vault.totalDebt(), 3758780024415885000);
        assertEq(vault.usdcBalance(), amount.mulWadUp(vault.floatPercentage())); // float
        assertApproxEq(vault.totalAssets(), amount, 1); // account for rounding error
    }

    function test_rebalance_DoesntDepositIfFloatRequirementIsGreaterThanBalance() public {
        deal(address(usdc), address(vault), 10000e6);

        vault.rebalance();

        // set float to 2%
        vault.setFloatPercentage(0.02e18);

        assertTrue(vault.usdcBalance() < vault.floatPercentage().mulWadDown(vault.totalAssets()));

        uint256 collateralBefore = vault.totalCollateralSupplied();

        vault.rebalance();

        assertEq(vault.totalCollateralSupplied(), collateralBefore);
    }

    function test_rebalance_RespectsRequiredFloatAmount() public {
        uint256 amount = 10000e6;
        uint256 floatRequired = 200e6; // 2%
        deal(address(usdc), address(vault), amount);
        vault.setFloatPercentage(0.02e18);

        vault.rebalance();

        assertEq(vault.usdcBalance(), floatRequired);
        assertApproxEq(vault.totalCollateralSupplied(), amount - floatRequired, 1); // account for rounding error
    }

    function test_rebalance_RespectsTargetLtvPercentage() public {
        deal(address(usdc), address(vault), 10000e6);

        assertEq(vault.getLtv(), 0);

        vault.rebalance();

        assertTrue(vault.getLtv() <= vault.targetLtv());
        assertApproxEq(vault.getLtv(), vault.targetLtv(), 0.001e18);
    }

    /// #applyNewTargetLtv ///

    function test_applyNewTargetLtv_ChangesLtvUpAndRebalances() public {
        deal(address(usdc), address(vault), 10000e6);

        vault.rebalance();

        uint256 oldTargetLtv = vault.targetLtv();
        uint256 debtBefore = vault.totalDebt();
        // add 10% to target ltv
        uint256 newTargetLtv = oldTargetLtv.mulWadUp(1.1e18);

        vault.applyNewTargetLtv(newTargetLtv);

        assertEq(vault.targetLtv(), newTargetLtv);
        assertApproxEqRel(vault.getLtv(), newTargetLtv, 0.001e18);
        assertApproxEqRel(vault.totalDebt(), debtBefore.mulWadUp(1.1e18), 0.001e18);
    }

    function test_applyNewTargetLtv_ChangesLtvDownAndRebalances() public {
        deal(address(usdc), address(vault), 10000e6);

        vault.rebalance();

        uint256 oldTargetLtv = vault.targetLtv();
        uint256 debtBefore = vault.totalDebt();
        // subtract 10% from target ltv
        uint256 newTargetLtv = oldTargetLtv.mulWadDown(0.9e18);

        vault.applyNewTargetLtv(newTargetLtv);

        assertEq(vault.targetLtv(), newTargetLtv);
        assertApproxEqRel(vault.getLtv(), newTargetLtv, 0.001e18);
        assertApproxEqRel(vault.totalDebt(), debtBefore.mulWadUp(0.9e18), 0.001e18);
    }

    function test_applyNewTargetLtv_FailsIfNewLtvIsTooHigh() public {
        deal(address(usdc), address(vault), 10000e6);

        uint256 tooHighLtv = vault.maxLtv() + 1;

        vm.expectRevert(scUSDC.InvalidUsdcWethTargetLtv.selector);
        vault.applyNewTargetLtv(tooHighLtv);
    }

    function test_applyNewTargetLtv_WorksIfNewLtvIs0() public {
        deal(address(usdc), address(vault), 10000e6);

        vault.rebalance();

        assertTrue(vault.getLtv() > 0);
        uint256 collateralBefore = vault.totalCollateralSupplied();

        vault.applyNewTargetLtv(0);

        assertEq(vault.getLtv(), 0);
        assertEq(vault.totalDebt(), 0);
        assertEq(vault.totalCollateralSupplied(), collateralBefore);
    }

    /// #totalAssets ///

    function test_totalAssets_CorrectlyAccountsAssetsAndLiabilities() public {
        uint256 amount = 10000e6;
        deal(address(usdc), address(vault), amount);

        vault.rebalance();

        assertApproxEq(vault.totalAssets(), amount, 1);

        vault.applyNewTargetLtv(0.5e18);

        assertApproxEq(vault.totalAssets(), amount, 1);
    }

    function test_totalAssets_AccountsProfitsMade() public {
        uint256 amount = 10000e6;
        deal(address(usdc), address(vault), amount);

        vault.rebalance();

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested * 2);

        // ~65% profit because of 65% target ltv
        uint256 expectedProfit = amount.mulWadDown(vault.targetLtv());

        assertApproxEqRel(vault.totalAssets(), amount + expectedProfit, 0.005e18);
    }

    /// #withdraw ///

    function testFuzz_withdraw(uint256 amount) public {
        amount = bound(amount, 1e3, 1e12);
        deal(address(usdc), alice, amount);

        vm.startPrank(alice);

        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amount, alice);

        vm.stopPrank();

        vault.rebalance();

        uint256 assets = vault.convertToAssets(vault.balanceOf(alice));

        assertApproxEq(assets, amount, 1);

        vm.startPrank(alice);
        vault.withdraw(assets, alice, alice);

        assertApproxEq(vault.balanceOf(alice), 0, 1);
        assertApproxEq(vault.totalAssets(), 0, 1);
        assertRelApproxEq(usdc.balanceOf(alice), amount, 0.001e18);

        vm.stopPrank();
    }

    function test_withdraw_UsesAssetsFromFloatFirst() public {
        uint256 deposit = 10000e6;
        deal(address(usdc), alice, deposit);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        vault.setFloatPercentage(0.5e18);
        vault.rebalance();

        uint256 floatBefore = vault.usdcBalance();
        uint256 collateralBefore = vault.totalCollateralSupplied();

        assertApproxEq(floatBefore, deposit / 2, 1);
        assertApproxEq(collateralBefore, deposit / 2, 1);

        uint256 withdrawAmount = 5000e6;
        vm.startPrank(alice);
        vault.withdraw(withdrawAmount, address(alice), address(alice));
        vm.stopPrank();

        assertApproxEq(usdc.balanceOf(alice), withdrawAmount, 1);
        assertApproxEq(vault.totalAssets(), deposit - withdrawAmount, 1);
        assertEq(vault.usdcBalance(), floatBefore - withdrawAmount);
        assertEq(vault.totalCollateralSupplied(), collateralBefore);
    }

    function test_withdraw_UsesAssetsFromProfitsSecond() public {
        uint256 deposit = 10000e6;
        deal(address(usdc), alice, deposit);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        vault.rebalance();

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested * 2);

        uint256 collateralBefore = vault.totalCollateralSupplied();
        uint256 totalAssetsBefore = vault.totalAssets();

        uint256 withdrawAmount = 5000e6;
        vm.startPrank(alice);
        vault.withdraw(withdrawAmount, address(alice), address(alice));
        vm.stopPrank();

        assertApproxEq(usdc.balanceOf(alice), withdrawAmount, 1);
        assertApproxEq(vault.totalAssets(), totalAssetsBefore - withdrawAmount, 0.001e18);
        assertEq(vault.totalCollateralSupplied(), collateralBefore);
        // float is maintained
        uint256 floatExpeced = vault.totalAssets().mulWadDown(vault.floatPercentage());
        assertApproxEqRel(vault.usdcBalance(), floatExpeced, 0.05e18);
    }

    function test_withdraw_UsesAssetsFromCollateralLast() public {
        uint256 deposit = 10000e6;
        deal(address(usdc), alice, deposit);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        vault.rebalance();

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested * 2);

        uint256 totalAssetsBefore = vault.totalAssets();

        uint256 withdrawAmount = 15000e6;
        vm.startPrank(alice);
        vault.withdraw(withdrawAmount, address(alice), address(alice));
        vm.stopPrank();

        assertApproxEq(usdc.balanceOf(alice), withdrawAmount, 1);
        assertApproxEq(vault.totalAssets(), totalAssetsBefore - withdrawAmount, 0.001e18);
        // float is maintained
        uint256 floatExpeced = vault.totalAssets().mulWadDown(vault.floatPercentage());
        assertApproxEqRel(vault.usdcBalance(), floatExpeced, 0.05e18);
        uint256 collateralExpected = totalAssetsBefore - floatExpeced - withdrawAmount;
        assertApproxEqRel(vault.totalCollateralSupplied(), collateralExpected, 0.01e18);
    }
}
