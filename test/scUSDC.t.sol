// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";

import {Constants as C} from "../src/lib/Constants.sol";
import {sc4626} from "../src/sc4626.sol";
import {scUSDC} from "../src/steth/scUSDC.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {ISwapRouter} from "../src/interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {MockSwapRouter} from "./mock/MockSwapRouter.sol";

contract scUSDCTest is Test {
    using FixedPointMathLib for uint256;

    event NewTargetLtvApplied(address indexed admin, uint256 newTargetLtv);
    event SlippageToleranceUpdated(address indexed admin, uint256 newSlippageTolerance);
    event EmergencyExitExecuted(
        address indexed admin, uint256 wethWithdrawn, uint256 debtRepaid, uint256 collateralReleased
    );
    event Rebalanced(
        uint256 targetLtv,
        uint256 initialDebt,
        uint256 finalDebt,
        uint256 initialCollateral,
        uint256 finalCollateral,
        uint256 initialUsdcBalance,
        uint256 finalUsdcBalance
    );

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

        usdc = ERC20(C.USDC);
        weth = WETH(payable(C.WETH));

        scWETH.ConstructorParams memory scWethParams = scWETH.ConstructorParams({
            admin: address(this),
            targetLtv: 0.7e18,
            slippageTolerance: 0.99e18,
            aavePool: IPool(C.AAVE_POOL),
            aaveAwstEth: IAToken(C.AAVE_AWSTETH_TOKEN),
            aaveVarDWeth: ERC20(C.AAVAAVE_VAR_DEBT_WETH_TOKEN),
            curveEthStEthPool: ICurvePool(C.CURVE_ETH_STETH_POOL),
            stEth: ILido(C.STETH),
            wstEth: IwstETH(C.WSTETH),
            weth: WETH(payable(C.WETH)),
            stEthToEthPriceFeed: AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED),
            balancerVault: IVault(C.BALANCER_VAULT)
        });

        wethVault = new scWETH(scWethParams);

        scUSDC.ConstructorParams memory params = createDefaultUsdcVaultConstructorParams(wethVault);

        vault = new scUSDC(params);

        // set vault eth balance to zero
        vm.deal(address(vault), 0);
    }

    /// #constructor ///

    function test_constructor() public {
        assertEq(address(vault.asset()), address(usdc));
        assertEq(address(vault.scWETH()), address(wethVault));

        // check approvals
        assertEq(usdc.allowance(address(vault), address(vault.aavePool())), type(uint256).max, "usdc->aave appor");

        assertEq(weth.allowance(address(vault), address(vault.aavePool())), type(uint256).max, "weth->aave allowance");
        assertEq(
            weth.allowance(address(vault), address(vault.swapRouter())), type(uint256).max, "weth->swapRouter allowance"
        );
        assertEq(weth.allowance(address(vault), address(vault.scWETH())), type(uint256).max, "weth->scWETH allowance");
    }

    /// #getMaxLtv ///

    function test_getMaxLtv() public {
        // max ltv for usdc reserve asset on aave is 0.74 at forked block
        assertEq(vault.getMaxLtv(), 0.74e18);
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

    function test_rebalance_DepositsUsdcAndBorrowsWeth() public {
        uint256 amount = 10000e6;
        deal(address(usdc), address(vault), amount);

        vault.rebalance();

        assertApproxEqAbs(vault.getCollateral(), amount.mulWadDown(0.99e18), 1, "collateral"); // - float
        assertEq(vault.getDebt(), 3_758780025000000000, "debt");
        assertEq(vault.getUsdcBalance(), amount.mulWadUp(vault.floatPercentage()), "float");
        assertApproxEqAbs(vault.totalAssets(), amount, 1, "total assets");
    }

    function test_rebalance_EmitsEventOnSuccess() public {
        uint256 initialBalance = 10000e6;
        uint256 finalBalance = initialBalance.mulWadUp(vault.floatPercentage());
        uint256 currentDebt = 0;
        uint256 finalDebt = 3_758780025000000000;
        uint256 currentCollateral = 0;
        uint256 finalCollateral = 9_900e6;
        uint256 targetLtv = vault.targetLtv();

        deal(address(usdc), address(vault), initialBalance);

        vm.expectEmit(true, true, true, true);
        emit Rebalanced(
            targetLtv, currentDebt, finalDebt, currentCollateral, finalCollateral, initialBalance, finalBalance
        );
        vault.rebalance();
    }

    function test_rebalance_DoesntDepositIfFloatRequirementIsGreaterThanBalance() public {
        deal(address(usdc), address(vault), 10000e6);

        vault.rebalance();

        // set float to 2%
        vault.setFloatPercentage(0.02e18);

        uint256 floatExpected = vault.floatPercentage().mulWadDown(vault.totalAssets());
        assertTrue(vault.getUsdcBalance() < floatExpected, "float requirement is not greater than balance");

        uint256 collateralBefore = vault.getCollateral();

        vault.rebalance();

        assertEq(vault.getCollateral(), collateralBefore, "collateral");
    }

    function test_rebalance_DoesntDepositIfAssetsLessThanMin() public {
        deal(address(usdc), address(vault), vault.rebalanceMinimum() - 1);

        vault.setFloatPercentage(0);

        vault.rebalance();

        assertEq(vault.getCollateral(), 0, "collateral");
        assertApproxEqAbs(vault.getUsdcBalance(), vault.rebalanceMinimum(), 1, "float");
    }

    function test_rebalance_DoesntDepositIfAssetsLessThanMin2() public {
        deal(address(usdc), address(vault), vault.rebalanceMinimum());

        vault.setFloatPercentage(0);

        vault.rebalance();

        assertApproxEqAbs(vault.getCollateral(), vault.rebalanceMinimum(), 1, "collateral");
        assertEq(vault.getUsdcBalance(), 0, "float");
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

    function test_rebalance_SellsProfitsAndConvertsToAdditionalCollateral() public {
        uint256 initialBalance = 10000e6;
        deal(address(usdc), address(vault), initialBalance);

        vault.rebalance();

        uint256 ltv = vault.getLtv();
        uint256 collateralBefore = vault.getCollateral();
        uint256 debtBefore = vault.getDebt();
        uint256 floatBefore = vault.getUsdcBalance();
        uint256 totalAssetsBefore = vault.totalAssets();

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested * 2);

        assertApproxEqRel(vault.totalAssets(), totalAssetsBefore.mulWadUp(1e18 + ltv), 0.01e18);

        vault.rebalance();

        assertApproxEqRel(vault.getCollateral(), collateralBefore.mulWadUp(1e18 + ltv), 0.01e18);
        assertApproxEqRel(vault.getDebt(), debtBefore.mulWadUp(1e18 + ltv), 0.01e18);
        assertApproxEqRel(vault.getUsdcBalance(), floatBefore.mulWadUp(1e18 + ltv), 0.01e18);
    }

    function test_rebalance_DoesntRebalanceForSmallProfit() public {
        uint256 initialBalance = 10000e6;
        deal(address(usdc), address(vault), initialBalance);

        vault.rebalance();

        uint256 collateralBefore = vault.getCollateral();
        uint256 debtBefore = vault.getDebt();
        uint256 floatBefore = vault.getUsdcBalance();
        uint256 totalAssetsBefore = vault.totalAssets();

        // add 1% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested.mulWadUp(1.01e18));

        assertTrue(vault.totalAssets() > totalAssetsBefore);

        vault.rebalance();

        assertEq(vault.getCollateral(), collateralBefore);
        assertEq(vault.getDebt(), debtBefore);
        assertEq(vault.getUsdcBalance(), floatBefore);
    }

    function testFuzz_rebalance(uint256 amount) public {
        vault.setFloatPercentage(0);
        uint256 lowerBound = vault.rebalanceMinimum().divWadUp(1e18 - vault.floatPercentage());
        amount = bound(amount, lowerBound, 10_000_000e6);
        deal(address(usdc), address(vault), amount);

        vault.rebalance();

        uint256 collateralBefore = vault.getCollateral();
        uint256 debtBefore = vault.getDebt();
        uint256 floatBefore = vault.getUsdcBalance();
        uint256 totalAssetsBefore = vault.totalAssets();

        uint256 wethInvested = weth.balanceOf(address(wethVault));
        // add enough profit to make total assets double
        uint256 profit = wethInvested + wethInvested.mulDivUp(1e18, vault.getLtv());
        assertTrue(wethInvested > 0, "wethInvested must be > 0");
        deal(address(weth), address(wethVault), profit);

        vault.rebalance();

        assertApproxEqRel(vault.totalAssets(), totalAssetsBefore * 2, 0.01e18);
        assertApproxEqRel(vault.getCollateral(), collateralBefore * 2, 0.01e18, "collateral");
        assertApproxEqRel(vault.getDebt(), debtBefore * 2, 0.01e18, "debt");
        assertApproxEqRel(vault.getUsdcBalance(), floatBefore * 2, 0.01e18, "float");
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
        emit NewTargetLtvApplied(address(this), newTargetLtv);

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

    function test_totalAssets_AccountProfitsMade() public {
        uint256 amount = 10000e6;
        deal(address(usdc), address(vault), amount);

        vault.rebalance();

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested * 2);

        // ~65% profit because of 65% target ltv
        uint256 expectedProfit = amount.mulWadDown(vault.getLtv()).mulWadDown(vault.slippageTolerance());

        assertApproxEqRel(vault.totalAssets(), amount + expectedProfit, 0.005e18, "total assets");
    }

    function test_totalAssets_AccountSlippageOnProfitsMade() public {
        uint256 amount = 10000e6;
        deal(address(usdc), address(vault), amount);

        vault.rebalance();

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested * 2);

        uint256 totalBefore = vault.totalAssets();
        uint256 profit = totalBefore - amount;

        // decrease slippage tolerance by 1%
        uint256 newSlippageTolerance = vault.slippageTolerance() - 0.01e18;
        vault.setSlippageTolerance(newSlippageTolerance);

        assertTrue(vault.totalAssets() < totalBefore, "total assets should be less than before");

        assertApproxEqRel(
            vault.totalAssets(),
            totalBefore - profit.mulWadDown(1e18 - vault.slippageTolerance()),
            0.005e18,
            "total assets"
        );
    }

    /// #withdraw ///

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
        assertTrue(vault.getUsdcBalance() >= floatExpeced, "vault float");
    }

    function test_withdraw_UsesAssetsFromProfitsOnlyWhenFloatIs0() public {
        uint256 deposit = 10000e6;
        deal(address(usdc), alice, deposit);

        vault.setFloatPercentage(0);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        vault.rebalance();

        assertEq(vault.getUsdcBalance(), 0, "vault float");

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
        assertTrue(vault.getUsdcBalance() >= floatExpeced, "vault float");
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
        assertApproxEqRel(vault.totalAssets(), totalAssetsBefore - withdrawAmount, 0.05e18, "vault total assets");
        // float is maintained
        uint256 floatExpeced = vault.totalAssets().mulWadDown(vault.floatPercentage());
        assertApproxEqRel(vault.getUsdcBalance(), floatExpeced, 0.05e18, "vault float");
        uint256 collateralExpected = totalAssetsBefore - floatExpeced - withdrawAmount;
        assertTrue(vault.getCollateral() >= collateralExpected, "vault collateral");
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
        assertApproxEqRel(vault.getCollateral(), totalCollateralBefore.mulWadUp(0.005e18), 1e18, "vault collateral");
        assertApproxEqRel(vault.totalAssets(), totalAssetsBefore.mulWadUp(0.005e18), 1e18, "vault total assets");
    }

    function test_withdraw_WorksWithdrawingMaxWhenFloatIs0() public {
        // redeploy vault with mock router because swapping usdc at current block results in "positive" slippage
        MockSwapRouter mockRouter = new MockSwapRouter();
        deal(address(usdc), address(mockRouter), 10_000_000e6);

        scUSDC.ConstructorParams memory params = createDefaultUsdcVaultConstructorParams(wethVault);
        params.uniswapSwapRouter = mockRouter;

        vault = new scUSDC(params);

        vault.setFloatPercentage(0);

        uint256 deposit = 10000e6;
        deal(address(usdc), alice, deposit);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        vault.rebalance();

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested.mulWadUp(2e18));

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

    function test_withdraw_FailsIfAmountOutIsLessThanMinWhenSellingProfits() public {
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

    function test_withdraw_WorksWhenVaultIsUnderwater() public {
        uint256 deposit = 10000e6;
        deal(address(usdc), alice, deposit);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        vault.rebalance();

        // 50% loss to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested / 2);

        uint256 totalBefore = vault.totalAssets();
        uint256 ltvBefore = vault.getLtv();

        // we should be able to withdraw half of the deposit
        uint256 withdrawAmount = deposit / 2;
        vm.startPrank(alice);
        vault.withdraw(withdrawAmount, address(alice), address(alice));
        vm.stopPrank();

        assertApproxEqAbs(usdc.balanceOf(alice), withdrawAmount, 1, "alice's usdc balance");
        assertApproxEqRel(vault.totalAssets(), totalBefore - withdrawAmount, 0.005e18, "vault total assets");
        assertApproxEqRel(vault.getCollateral(), deposit - withdrawAmount, 0.01e18, "vault collateral");
        // ltv should not change
        assertApproxEqRel(vault.getLtv(), ltvBefore, 0.001e18, "vault ltv");
    }

    function test_withdraw_FailsIfWithdrawingMoreWhenVaultIsUnderwater() public {
        uint256 deposit = 10000e6;
        deal(address(usdc), alice, deposit);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        vault.rebalance();

        // 50% loss to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested / 2);

        // we cannot withdraw evertying because we don't have enough to repay the debt
        uint256 withdrawAmount = vault.totalAssets();
        vm.startPrank(alice);
        vm.expectRevert();
        vault.withdraw(withdrawAmount, address(alice), address(alice));
    }

    function testFuzz_withdraw(uint256 amount) public {
        amount = bound(amount, 1, 10_000_000e6); // upper limit constrained by weth available on aave
        deal(address(usdc), alice, amount);

        vm.startPrank(alice);

        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amount, alice);
        vm.stopPrank();

        vault.rebalance();

        uint256 assets = vault.convertToAssets(vault.balanceOf(alice));
        // due to rounding errors, we can't assert exact equality
        assertApproxEqAbs(assets, amount, 1, "assets");

        vm.startPrank(alice);
        vault.withdraw(assets, alice, alice);

        assertApproxEqAbs(vault.balanceOf(alice), 0, 1, "balance");
        assertApproxEqAbs(vault.totalAssets(), 0, 1, "total assets");
        assertApproxEqAbs(usdc.balanceOf(alice), amount, 0.01e6, "usdc balance");
    }

    function testFuzz_withdraw_WhenInProfit(uint256 amount) public {
        uint256 lowerBound = vault.rebalanceMinimum().divWadUp(1e18 - vault.floatPercentage());
        amount = bound(amount, lowerBound, 10_000_000e6); // upper limit constrained by weth available on aave
        deal(address(usdc), alice, amount);

        vm.startPrank(alice);

        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amount, alice);

        vm.stopPrank();

        vault.rebalance();

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested * 2);

        uint256 assets = vault.convertToAssets(vault.balanceOf(alice));
        // some assets can be left in the vault because of slippage when selling profits
        uint256 toleratedLeftover = vault.totalAssets().mulWadUp(1e18 - vault.slippageTolerance());

        assertApproxEqRel(assets, amount.mulWadDown(1e18 + vault.getLtv()), 0.01e18, "assets");

        vm.startPrank(alice);
        vault.withdraw(assets, alice, alice);

        assertApproxEqAbs(vault.balanceOf(alice), 0, 1, "balance");
        assertApproxEqRel(usdc.balanceOf(alice), amount.mulWadDown(1e18 + vault.targetLtv()), 0.01e18, "usdc balance");
        assertTrue(vault.totalAssets() <= toleratedLeftover, "total assets");
    }

    /// #redeem ///

    function testFuzz_redeem_WhenInProfit(uint256 amount) public {
        uint256 lowerBound = vault.rebalanceMinimum().divWadUp(1e18 - vault.floatPercentage());
        amount = bound(amount, lowerBound, 10_000_000e6); // upper limit constrained by weth available on aave
        deal(address(usdc), alice, amount);

        vm.startPrank(alice);

        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(amount, alice);

        vm.stopPrank();

        vault.rebalance();

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested * 2);

        uint256 shares = vault.balanceOf(alice);
        // some assets can be left in the vault because of slippage when selling profits
        uint256 toleratedLeftover = vault.totalAssets().mulWadUp(1e18 - vault.slippageTolerance());

        vm.startPrank(alice);
        vault.redeem(shares, alice, alice);

        assertEq(vault.balanceOf(alice), 0, "balance");
        assertApproxEqRel(usdc.balanceOf(alice), amount.mulWadDown(1e18 + vault.targetLtv()), 0.01e18, "usdc balance");
        assertTrue(vault.totalAssets() <= toleratedLeftover, "total assets");
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
        emit SlippageToleranceUpdated(address(this), newTolerance);

        vault.setSlippageTolerance(newTolerance);

        assertEq(vault.slippageTolerance(), newTolerance, "slippage tolerance");
    }

    /// #exitAllPositions ///

    function test_exitAllPositions_FailsIfCallerIsNotAdmin() public {
        vm.startPrank(alice);
        vm.expectRevert(sc4626.CallerNotAdmin.selector);
        vault.exitAllPositions();
    }

    function test_exitAllPositions_FailsIfVaultIsNotUnderawater() public {
        uint256 deposit = 1_000_000e6;
        deal(address(usdc), alice, deposit);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        vault.rebalance();

        vm.expectRevert(scUSDC.VaultNotUnderwater.selector);
        vault.exitAllPositions();
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateral() public {
        uint256 deposit = 1_000_000e6;
        deal(address(usdc), alice, deposit);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        vault.rebalance();

        // simulate 50% loss
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested / 2);

        uint256 totalBefore = vault.totalAssets();

        vault.exitAllPositions();

        assertApproxEqRel(vault.getUsdcBalance(), totalBefore, 0.01e18, "vault usdc balance");
        assertEq(vault.getCollateral(), 0, "vault collateral");
        assertEq(vault.getDebt(), 0, "vault debt");
    }

    function test_exitAllPositions_EmitsEventOnSuccess() public {
        uint256 deposit = 1_000_000e6;
        deal(address(usdc), alice, deposit);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(deposit, alice);
        vm.stopPrank();

        vault.rebalance();

        // simulate 50% loss
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested / 2);

        uint256 invested = vault.getInvested();
        uint256 debt = vault.getDebt();
        uint256 collateral = vault.getCollateral();

        vm.expectEmit(true, true, true, true);
        emit EmergencyExitExecuted(address(this), invested, debt, collateral);
        vault.exitAllPositions();
    }

    /// #receiveFlashLoan ///

    function test_receiveFlashLoan_FailsIfCallerIsNotFlashLoaner() public {
        vm.startPrank(alice);
        vm.expectRevert(scUSDC.InvalidFlashLoanCaller.selector);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory feeAmounts = new uint256[](1);

        vault.receiveFlashLoan(tokens, amounts, feeAmounts, bytes("0"));
    }

    /// internal helper functions ///

    function createDefaultUsdcVaultConstructorParams(scWETH scWeth)
        internal
        view
        returns (scUSDC.ConstructorParams memory)
    {
        return scUSDC.ConstructorParams({
            admin: address(this),
            scWETH: scWeth,
            usdc: ERC20(C.USDC),
            weth: WETH(payable(C.WETH)),
            aavePool: IPool(C.AAVE_POOL),
            aavePoolDataProvider: IPoolDataProvider(C.AAVE_POOL_DATA_PROVIDER),
            aaveAUsdc: IAToken(C.AAVE_AUSDC_TOKEN),
            aaveVarDWeth: ERC20(C.AAVAAVE_VAR_DEBT_WETH_TOKEN),
            uniswapSwapRouter: ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER),
            chainlinkUsdcToEthPriceFeed: AggregatorV3Interface(C.CHAINLINK_USDC_ETH_PRICE_FEED),
            balancerVault: IVault(C.BALANCER_VAULT)
        });
    }
}
