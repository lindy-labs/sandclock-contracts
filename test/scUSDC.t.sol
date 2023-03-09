// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {sc4626} from "../src/sc4626.sol";
import {scUSDC} from "../src/steth/scUSDC.sol";
import {scWETH} from "../src/steth/scWETH.sol";

contract scUSDCTest is Test {
    using FixedPointMathLib for uint256;

    event NewTargetLtvApplied(uint256 newtargetLtv);
    event SlippageToleranceUpdated(uint256 newSlippageTolerance);
    event Rebalanced(uint256 collateral, uint256 debt, uint256 ltv);

    uint256 mainnetFork;
    uint256 constant ethWstEthMaxLtv = 0.7735e18;
    uint256 constant slippageTolerance = 0.999e18;
    uint256 constant flashLoanLtv = 0.5e18;

    // dummy users
    address constant alice = address(0x06);

    scUSDC vault;
    scWETH wethVault;

    WETH weth;
    ERC20 usdc;

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
        assertEq(vault.eul().allowance(address(vault), vault.xrouter()), 0, "eul->0xruter allowance");
    }

    /// #getMaxLtv ///

    function test_maxLtv() public {
        // at the current fork block, usdc collateral factor = 0.9 & weth borrow factor = 0.91
        // maxLtv = 0.9 * 0.91 = 0.819
        assertEq(vault.getMaxLtv(), 0.819e18);
    }

    /// #deposit ///

    function testFuzz_deposit(uint256 amount) public {
        amount = bound(amount, 1, 1e18);
        deal(address(usdc), alice, amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);

        vault.deposit(amount, alice);

        vm.stopPrank();

        assertEq(vault.convertToAssets(vault.balanceOf(alice)), amount, "balance");
    }

    /// #rebalance ///

    function test_rebalance_DepositsUsdcAndBorrowsWethOnEuler() public {
        uint256 amount = 10000e6;
        deal(address(usdc), address(vault), amount);

        vault.rebalance();

        assertApproxEqAbs(vault.getCollateral(), amount.mulWadDown(0.99e18), 1, "collateral"); // - float
        assertEq(vault.getDebt(), 3_758780025000000000, "debt");
        assertEq(vault.getUsdcBalance(), amount.mulWadUp(vault.floatPercentage()), "float");
        assertApproxEqAbs(vault.totalAssets(), amount, 1, "total assets");
    }

    function test_rebalance_EmitsEventOnSuccess() public {
        deal(address(usdc), address(vault), 10000e6);

        vm.expectEmit(true, true, true, true);
        emit Rebalanced(9899_999999, 3_758780025000000000, 0.650000000065656566e18);

        vault.rebalance();
    }

    function test_rebalance_DoesntDepositIfFloatRequirementIsGreaterThanBalance() public {
        deal(address(usdc), address(vault), 10000e6);

        vault.rebalance();

        // set float to 2%
        vault.setFloatPercentage(0.02e18);

        uint256 floatExpected = vault.floatPercentage().mulWadDown(vault.totalAssets());
        assertTrue(vault.getUsdcBalance() < floatExpected);

        uint256 collateralBefore = vault.getCollateral();

        vault.rebalance();

        assertEq(vault.getCollateral(), collateralBefore);
    }

    function test_rebalance_RespectsRequiredFloatAmount() public {
        uint256 amount = 10000e6;
        uint256 floatRequired = 200e6; // 2%
        deal(address(usdc), address(vault), amount);
        vault.setFloatPercentage(0.02e18);

        vault.rebalance();

        assertEq(vault.getUsdcBalance(), floatRequired, "float");
        uint256 collateralExpected = amount - floatRequired;
        assertApproxEqAbs(vault.getCollateral(), collateralExpected, 1, "collateral");
    }

    function test_rebalance_RespectsTargetLtvPercentage() public {
        deal(address(usdc), address(vault), 10000e6);

        // no debt yet
        assertEq(vault.getLtv(), 0);

        vault.rebalance();

        assertApproxEqRel(vault.getLtv(), vault.targetLtv(), 0.001e18);
    }

    function test_rebalance_DoesntRebalanceWhenLtvIsWithinRange() public {
        uint256 initialBalance = 10000e6;
        deal(address(usdc), address(vault), initialBalance);

        // no debt yet
        assertEq(vault.getLtv(), 0);

        vault.rebalance();

        uint256 collateralBefore = vault.getCollateral();
        uint256 debtBefore = vault.getDebt();

        // add 1% more assets
        deal(address(usdc), address(vault), vault.totalAssets().mulWadUp(0.01e18));

        vault.rebalance();

        assertEq(vault.getCollateral(), collateralBefore);
        assertEq(vault.getDebt(), debtBefore);
    }

    /// #applyNewTargetLtv ///

    function test_applyNewTargetLtv_FailsIfCallerIsNotKeeper() public {
        uint256 newTargetLtv = vault.targetLtv() / 2;

        vm.startPrank(alice);
        vm.expectRevert(sc4626.CallerNotKeeper.selector);
        vault.applyNewTargetLtv(newTargetLtv);
    }

    function test_applyNewTargetLtv_EmitsEventOnSuccess() public {
        uint256 newTargetLtv = vault.targetLtv() / 2;

        vm.expectEmit(true, true, true, true);
        emit NewTargetLtvApplied(newTargetLtv);

        vault.applyNewTargetLtv(newTargetLtv);
    }

    function test_applyNewTargetLtv_ChangesLtvUpAndRebalances() public {
        deal(address(usdc), address(vault), 10000e6);

        vault.rebalance();

        uint256 oldTargetLtv = vault.targetLtv();
        uint256 debtBefore = vault.getDebt();
        // add 10% to target ltv
        uint256 newTargetLtv = oldTargetLtv.mulWadUp(1.1e18);

        vault.applyNewTargetLtv(newTargetLtv);

        assertEq(vault.targetLtv(), newTargetLtv, "target ltv");
        assertApproxEqRel(vault.getLtv(), newTargetLtv, 0.001e18, "ltv");
        assertApproxEqRel(vault.getDebt(), debtBefore.mulWadUp(1.1e18), 0.001e18, "debt");
    }

    function test_applyNewTargetLtv_ChangesLtvDownAndRebalances() public {
        deal(address(usdc), address(vault), 10000e6);

        vault.rebalance();

        uint256 oldTargetLtv = vault.targetLtv();
        uint256 debtBefore = vault.getDebt();
        // subtract 10% from target ltv
        uint256 newTargetLtv = oldTargetLtv.mulWadDown(0.9e18);

        vault.applyNewTargetLtv(newTargetLtv);

        assertEq(vault.targetLtv(), newTargetLtv, "target ltv");
        assertApproxEqRel(vault.getLtv(), newTargetLtv, 0.001e18, "ltv");
        assertApproxEqRel(vault.getDebt(), debtBefore.mulWadUp(0.9e18), 0.001e18, "debt");
    }

    function test_applyNewTargetLtv_FailsIfNewLtvIsTooHigh() public {
        deal(address(usdc), address(vault), 10000e6);

        uint256 tooHighLtv = vault.getMaxLtv() + 1;

        vm.expectRevert(scUSDC.InvalidTargetLtv.selector);
        vault.applyNewTargetLtv(tooHighLtv);
    }

    function test_applyNewTargetLtv_WorksIfNewLtvIs0() public {
        deal(address(usdc), address(vault), 10000e6);

        vault.rebalance();

        assertTrue(vault.getLtv() > 0);
        uint256 collateralBefore = vault.getCollateral();

        vault.applyNewTargetLtv(0);

        assertEq(vault.getLtv(), 0, "ltv");
        assertEq(vault.getDebt(), 0, "debt");
        assertEq(vault.getCollateral(), collateralBefore, "collateral");
    }

    /// #totalAssets ///

    function test_totalAssets_CorrectlyAccountsAssetsAndLiabilities() public {
        uint256 amount = 10000e6;
        deal(address(usdc), address(vault), amount);

        vault.rebalance();

        assertApproxEqAbs(vault.totalAssets(), amount, 1, "total assets before ltv change");

        vault.applyNewTargetLtv(0.5e18);

        assertApproxEqAbs(vault.totalAssets(), amount, 1, "total assets after ltv change");
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

        assertApproxEqRel(vault.totalAssets(), amount + expectedProfit, 0.005e18, "total assets");
    }

    /// #withdraw ///

    function testFuzz_withdraw(uint256 amount) public {
        amount = bound(amount, 1, 10_000_000e6); // upper limit constrained by weth available on euler
        deal(address(usdc), alice, amount);

        vm.startPrank(alice);

        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amount, alice);

        vm.stopPrank();

        vault.rebalance();

        uint256 assets = vault.convertToAssets(vault.balanceOf(alice));

        assertApproxEqAbs(assets, amount, 1, "assets");

        vm.startPrank(alice);
        vault.withdraw(assets, alice, alice);

        assertApproxEqAbs(vault.balanceOf(alice), 0, 1, "balance");
        assertApproxEqAbs(vault.totalAssets(), 0, 1, "total assets");
        assertApproxEqAbs(usdc.balanceOf(alice), amount, 0.01e6, "usdc balance");
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

        uint256 floatBefore = vault.getUsdcBalance();
        uint256 collateralBefore = vault.getCollateral();

        assertApproxEqAbs(floatBefore, deposit / 2, 1, "float before");
        assertApproxEqAbs(collateralBefore, deposit / 2, 1, "collateral before");

        uint256 withdrawAmount = 5000e6;
        vm.startPrank(alice);
        vault.withdraw(withdrawAmount, address(alice), address(alice));
        vm.stopPrank();

        assertApproxEqAbs(usdc.balanceOf(alice), withdrawAmount, 1, "alice's usdc balance");
        assertApproxEqAbs(vault.totalAssets(), deposit - withdrawAmount, 1, "vault total assets");
        assertEq(vault.getUsdcBalance(), floatBefore - withdrawAmount, "vault float");
        assertEq(vault.getCollateral(), collateralBefore, "vault collateral");
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

        uint256 collateralBefore = vault.getCollateral();
        uint256 totalAssetsBefore = vault.totalAssets();

        uint256 withdrawAmount = 5000e6;
        vm.startPrank(alice);
        vault.withdraw(withdrawAmount, address(alice), address(alice));
        vm.stopPrank();

        assertApproxEqAbs(usdc.balanceOf(alice), withdrawAmount, 1, "alice's usdc balance");
        assertApproxEqAbs(vault.totalAssets(), totalAssetsBefore - withdrawAmount, 0.001e18, "vault total assets");
        assertEq(vault.getCollateral(), collateralBefore, "vault collateral");
        // float is maintained
        uint256 floatExpeced = vault.totalAssets().mulWadDown(vault.floatPercentage());
        assertApproxEqRel(vault.getUsdcBalance(), floatExpeced, 0.05e18, "vault float");
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

        uint256 withdrawAmount = 15000e6; // this amount forces selling of whole profits
        vm.startPrank(alice);
        vault.withdraw(withdrawAmount, address(alice), address(alice));
        vm.stopPrank();

        assertApproxEqAbs(usdc.balanceOf(alice), withdrawAmount, 1, "alice's usdc balance");
        assertApproxEqRel(vault.totalAssets(), totalAssetsBefore - withdrawAmount, 0.005e18, "vault total assets");
        // float is maintained
        uint256 floatExpeced = vault.totalAssets().mulWadDown(vault.floatPercentage());
        assertApproxEqRel(vault.getUsdcBalance(), floatExpeced, 0.05e18, "vault float");
        uint256 collateralExpected = totalAssetsBefore - floatExpeced - withdrawAmount;
        assertApproxEqRel(vault.getCollateral(), collateralExpected, 0.01e18, "vault collateral");
    }

    function test_withdraw_WorksWhenWithdrawingMaxAvailable() public {
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
        uint256 totalCollateralBefore = vault.getCollateral();

        vm.startPrank(alice);
        vault.withdraw(totalAssetsBefore, address(alice), address(alice));
        vm.stopPrank();

        assertApproxEqAbs(usdc.balanceOf(alice), totalAssetsBefore, 1, "alice's usdc balance");
        assertApproxEqRel(vault.getUsdcBalance(), 0, 0.05e18, "vault float");
        // some dust can be left in as collateral
        assertApproxEqRel(vault.getCollateral(), totalCollateralBefore.mulWadUp(0.0005e18), 1e18, "vault collateral");
        assertApproxEqRel(vault.totalAssets(), totalAssetsBefore.mulWadUp(0.0005e18), 1e18, "vault total assets");
    }

    function test_withdraw_FailsIfAmountOutIsLessThanMinWhenSwappingWETHtoUSDC() public {
        uint256 deposit = 1_000_000e6;
        deal(address(usdc), alice, deposit);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        vault.rebalance();

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested * 2);

        vault.setSlippageTolerance(1e18);

        uint256 withdrawAmount = 1_000_000e6; // this amount forces selling of whole profits
        vm.startPrank(alice);
        vm.expectRevert("Too little received");
        vault.withdraw(withdrawAmount, address(alice), address(alice));
        vm.stopPrank();
    }

    /// #setSlippageTolerance ///

    function test_setSlippageTolerance_FailsIfCallerIsNotAdmin() public {
        uint256 tolerance = 0.01e18;

        vm.startPrank(alice);
        vm.expectRevert(sc4626.CallerNotAdmin.selector);
        vault.setSlippageTolerance(tolerance);
    }

    function test_setSlippageTolearnce_UpdatesSlippageTolerance() public {
        uint256 newTolerance = 0.01e18;

        vm.expectEmit(true, true, true, true);
        emit SlippageToleranceUpdated(newTolerance);

        vault.setSlippageTolerance(newTolerance);

        assertEq(vault.slippageTolerance(), newTolerance, "slippage tolerance");
    }

    /// #reinvestEulerRewards ///

    function test_reinvestEulerRewards_FailsIfCallerIsNotKeeper() public {
        vm.startPrank(alice);
        vm.expectRevert(sc4626.CallerNotKeeper.selector);
        vault.reinvestEulerRewards(bytes("0"));
    }

    function test_reinvestEulerRewards_SwapsEulForUsdcAndRebalances() public {
        vm.rollFork(16744453);
        // redeploy vault
        vault = new scUSDC(address(this), new scWETH(address(this)));

        deal(address(vault.eul()), address(vault), 1000e18);

        assertEq(vault.eul().balanceOf(address(vault)), 1000e18, "eul balance");
        assertEq(vault.getUsdcBalance(), 0, "usdc balance");
        assertEq(vault.totalAssets(), 0, "total assets");

        // data obtained from 0x api for swapping 1000 eul for ~7883 usdc
        // https://api.0x.org/swap/v1/quote?buyToken=USDC&sellToken=0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b&sellAmount=1000000000000000000000
        bytes memory swapData =
            hex"6af479b2000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000003635c9adc5dea0000000000000000000000000000000000000000000000000000000000001d16e269100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000042d9fcd98c322942075a5c3860693e9f4f03aae07b002710c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000064a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000e6464241aa64013c9d";

        vault.reinvestEulerRewards(swapData);

        assertEq(vault.eul().balanceOf(address(vault)), 0, "vault eul balance");
        assertEq(vault.totalAssets(), 7883_963201, "vault total assets");
        assertEq(vault.getUsdcBalance(), 78_839633, "vault usdc balance");
    }
}
