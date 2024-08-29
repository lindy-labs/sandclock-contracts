// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Constants as C} from "../src/lib/Constants.sol";
import {ILendingPool} from "../src/interfaces/aave-v2/ILendingPool.sol";
import {IProtocolDataProvider} from "../src/interfaces/aave-v2/IProtocolDataProvider.sol";
import {IAdapter} from "../src/steth/IAdapter.sol";
import {SparkScSDaiAdapter} from "../src/steth/scSDai-adapters/SparkScSDaiAdapter.sol";
import {scSDAI} from "../src/steth/scSDAI.sol";
import {SDaiWethPriceConverter} from "../src/steth/priceConverter/SDaiWethPriceConverter.sol";
import {scCrossAssetYieldVault} from "../src/steth/scCrossAssetYieldVault.sol";

import {scWETH} from "../src/steth/scWETH.sol";
import {PriceConverter} from "../src/steth/priceConverter/PriceConverter.sol";
import {ISwapRouter} from "../src/interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import "../src/errors/scErrors.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {MainnetAddresses as M} from "../script/base/MainnetAddresses.sol";
import {ISinglePairPriceConverter} from "../src/steth/priceConverter/IPriceConverter.sol";
import {ISinglePairSwapper} from "../src/steth/swapper/ISwapper.sol";
import {SDaiWethSwapper} from "../src/steth/swapper/SDaiWethSwapper.sol";

contract scSDAITest is Test {
    using Address for address;
    using FixedPointMathLib for uint256;

    event Disinvested(uint256 wethAmount);
    event WethSwappedForAsset(uint256 wethAmount, uint256 assetAmountOut);

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);

    WETH weth;
    ERC4626 sDai;
    ERC20 dai;

    scWETH wethVault = scWETH(payable(M.SCWETHV2));
    scSDAI vault;

    SparkScSDaiAdapter spark;
    ISinglePairSwapper swapper;
    ISinglePairPriceConverter priceConverter;

    uint256 pps;
    uint256 cleanStateSnapshot;

    constructor() Test() {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(19832667);

        sDai = ERC4626(C.SDAI);
        dai = ERC20(C.DAI);
        weth = WETH(payable(C.WETH));
        spark = new SparkScSDaiAdapter();

        pps = wethVault.totalAssets().divWadDown(wethVault.totalSupply());

        _deployAndSetUpVault();

        cleanStateSnapshot = vm.snapshot();
    }

    function setUp() public {
        vm.revertTo(cleanStateSnapshot);
    }

    /// #constructor ///

    function test_constructor() public {
        assertEq(address(vault.asset()), C.SDAI);
        assertEq(address(vault.targetVault()), address(wethVault), "weth vault");
        assertEq(address(vault.priceConverter()), address(priceConverter), "price converter");
        assertEq(address(vault.swapper()), address(swapper), "swapper");

        assertEq(weth.allowance(address(vault), address(vault.targetVault())), type(uint256).max, "scWETH allowance");
        assertEq(dai.allowance(address(vault), address(sDai)), type(uint256).max, "dai allowance");
    }

    function test_rebalance() public {
        uint256 initialBalance = 1_000_000e18;
        uint256 initialDebt = 100 ether;
        deal(address(sDai), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, spark.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, spark.id(), initialDebt);

        vault.rebalance(callData);

        assertEq(vault.totalDebt(), initialDebt, "total debt");
        assertEq(vault.totalCollateral(), initialBalance, "total collateral");

        _assertCollateralAndDebt(spark.id(), initialBalance, initialDebt);

        assertApproxEqRel(wethVault.balanceOf(address(vault)), initialDebt.divWadDown(pps), 1e5, "scETH shares");
    }

    function testFuzz_rebalance(uint256 supplyOnSpark, uint256 borrowOnSpark) public {
        uint256 floatPercentage = 0.01e18;
        // -10 to account for rounding error difference between debt vs invested amounts
        vault.setFloatPercentage(floatPercentage - 10);

        supplyOnSpark = bound(supplyOnSpark, 100e18, 1_000_000e18);
        borrowOnSpark = bound(
            borrowOnSpark,
            1e10,
            priceConverter.baseAssetToToken(supplyOnSpark).mulWadDown(spark.getMaxLtv() - 0.005e18) // -0.5% to avoid borrowing at max ltv
        );

        uint256 initialBalance = supplyOnSpark.divWadDown(1e18 - floatPercentage);
        uint256 minFloat = supplyOnSpark.mulWadDown(floatPercentage);

        deal(address(sDai), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, spark.id(), supplyOnSpark);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, spark.id(), borrowOnSpark);

        vault.rebalance(callData);

        _assertCollateralAndDebt(spark.id(), supplyOnSpark, borrowOnSpark);
        assertApproxEqAbs(vault.totalAssets(), initialBalance, 1e10, "total assets");
        assertApproxEqRel(vault.assetBalance(), minFloat, 0.05e18, "float");
    }

    function test_disinvest() public {
        uint256 initialBalance = 1_000_000e18;
        uint256 initialDebt = 100 ether;
        deal(address(sDai), address(vault), initialBalance);
        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, spark.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, spark.id(), initialDebt);
        vault.rebalance(callData);

        uint256 disinvestAmount = vault.targetTokenInvestedAmount() / 2;
        vault.disinvest(disinvestAmount);

        assertApproxEqRel(weth.balanceOf(address(vault)), disinvestAmount, 1e2, "weth balance");
        assertEq(vault.targetTokenInvestedAmount(), initialDebt - disinvestAmount, "weth invested");
    }

    function test_sellProfit() public {
        uint256 initialBalance = 100000e18;
        uint256 initialDebt = 10 ether;
        deal(address(sDai), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, spark.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, spark.id(), initialDebt);

        vault.rebalance(callData);

        // add 100% profit to the weth vault
        uint256 initialWethInvested = vault.targetTokenInvestedAmount();
        deal(address(weth), address(wethVault), initialWethInvested * 2);

        uint256 sDaiBalanceBefore = vault.assetBalance();
        uint256 profit = vault.getProfit();

        vm.prank(keeper);
        vault.sellProfit(0);

        uint256 expectedDaiBalance = sDaiBalanceBefore + priceConverter.tokenToBaseAsset(profit);
        _assertCollateralAndDebt(spark.id(), initialBalance, initialDebt);
        assertApproxEqRel(vault.assetBalance(), expectedDaiBalance, 0.01e18, "sDai balance");
        assertApproxEqRel(
            vault.targetTokenInvestedAmount(), initialWethInvested, 0.001e18, "sold more than actual profit"
        );
    }

    function test_lifi() public {
        uint256 amount = 10000000000000000000;
        address lifi = 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE;

        deal(C.WETH, address(this), amount);

        ERC20(C.WETH).approve(lifi, amount);

        assertEq(0, ERC20(C.SDAI).balanceOf(address(this)));
        assertEq(amount, ERC20(C.WETH).balanceOf(address(this)));

        bytes memory swapData =
            hex"878863a4a02f2e4a3e115e3d5285ade4a113cac81309fa4b93515ebe8d5a87760d8432d800000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000001000000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e14960000000000000000000000000000000000000000000005d0ccd1235c457d5c2b000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000000086c6966692d617069000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002a307830303030303030303030303030303030303030303030303030303030303030303030303030303030000000000000000000000000000000000000000000000000000000000000000000001111111254eeb25477b68fb85ed929f73a9605820000000000000000000000001111111254eeb25477b68fb85ed929f73a960582000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000083f20f44975d03b1b09e64809b757c47f942beea0000000000000000000000000000000000000000000000008ac7230489e8000000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000030812aa3caf000000000000000000000000e37e799d5077682fa0a244d46e5649f71457bd09000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000083f20f44975d03b1b09e64809b757c47f942beea000000000000000000000000e37e799d5077682fa0a244d46e5649f71457bd090000000000000000000000001231deb6f5749ef6ce6943a275a1d3e7486f4eae0000000000000000000000000000000000000000000000008ac7230489e800000000000000000000000000000000000000000000000005d0ccd1235c457d5c2a0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000001600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000017f0000000000000000000000000000000000000000000001610001330000e900a007e5c0d20000000000000000000000000000000000000000000000c500005500004f02a000000000000000000000000000000000000000000000000000000006dfdda0d1ee63c1e50088e6a0c2ddd26feeb64f039a2c41296fcb3f5640c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200a0fd53121f512083f20f44975d03b1b09e64809b757c47f942beea6b175474e89094c44da98b954eedeac495271d0f00046e553f650000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e37e799d5077682fa0a244d46e5649f71457bd0900a0f2fa6b6683f20f44975d03b1b09e64809b757c47f942beea0000000000000000000000000000000000000000000005d8480ea6c113ab03de00000000000000004013da5f59051fc280a06c4eca2783f20f44975d03b1b09e64809b757c47f942beea1111111254eeb25477b68fb85ed929f73a960582002a94d114000000000000000000000000000000000000000000000000";

        lifi.functionCall(swapData);

        assertEq(27582668726196102150894, ERC20(C.SDAI).balanceOf(address(this)));
        assertEq(0, ERC20(C.WETH).balanceOf(address(this)));
    }

    function test_withdrawFunds() public {
        uint256 initialBalance = 1_000_000e18;
        _deposit(alice, initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, spark.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, spark.id(), 100 ether);

        vault.rebalance(callData);

        uint256 withdrawAmount = vault.convertToAssets(vault.balanceOf(alice));
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(sDai.balanceOf(alice), withdrawAmount, "alice asset balance");
    }

    function testFuzz_withdraw(uint256 _amount, uint256 _withdrawAmount) public {
        _amount = 36072990718134180857610733478 * 1e12;
        _withdrawAmount = 0;
        _amount = bound(_amount, 1e18, 10_000_000e18); // upper limit constrained by weth available on aave v3
        _deposit(alice, _amount);

        uint256 borrowAmount = priceConverter.baseAssetToToken(_amount.mulWadDown(0.7e18));

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, spark.id(), _amount);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, spark.id(), borrowAmount);

        vault.rebalance(callData);

        uint256 total = vault.totalAssets();
        _withdrawAmount = bound(_withdrawAmount, 1e18, total);
        vm.startPrank(alice);
        vault.withdraw(_withdrawAmount, alice, alice);

        assertApproxEqAbs(vault.totalAssets(), total - _withdrawAmount, 0.0001e18, "total assets");
        assertApproxEqAbs(sDai.balanceOf(alice), _withdrawAmount, 0.01e18, "sdai balance");
    }

    function testFuzz_withdraw_whenInProfit(uint256 _amount, uint256 _withdrawAmount) public {
        _amount = 0;
        _amount = bound(_amount, 1e18, 10_000_000e18); // upper limit constrained by weth available on aave v3
        deal(address(sDai), alice, _amount);
        console2.log("amount", _amount);

        vm.startPrank(alice);
        sDai.approve(address(vault), type(uint256).max);
        vault.deposit(_amount, alice);
        vm.stopPrank();

        uint256 borrowAmount = priceConverter.baseAssetToToken(_amount.mulWadDown(0.7e18));

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, spark.id(), _amount);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, spark.id(), borrowAmount);

        vault.rebalance(callData);

        // add 10% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested.mulWadUp(1.1e18));

        uint256 total = vault.totalAssets();
        _withdrawAmount = bound(_withdrawAmount, 1e18, total);
        vm.startPrank(alice);
        vault.withdraw(_withdrawAmount, alice, alice);

        assertApproxEqAbs(vault.totalAssets(), total - _withdrawAmount, total.mulWadDown(0.001e18), "total assets");
        assertApproxEqAbs(sDai.balanceOf(alice), _withdrawAmount, _amount.mulWadDown(0.001e18), "sDai balance");
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralNoProfit() public {
        uint256 initialBalance = 1_000_000e18;
        deal(address(sDai), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, spark.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, spark.id(), 100 ether);

        vault.rebalance(callData);

        assertEq(vault.getProfit(), 0, "profit");

        uint256 totalBefore = vault.totalAssets();

        vault.exitAllPositions(0);

        assertApproxEqRel(vault.assetBalance(), totalBefore, 0.001e18, "vault asset balance");
        assertEq(weth.balanceOf(address(vault)), 0, "weth balance");
        assertEq(vault.targetTokenInvestedAmount(), 0, "weth invested");
        assertEq(vault.totalCollateral(), 0, "total collateral");
        assertEq(vault.totalDebt(), 0, "total debt");
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralOnOneProtocolWhenUnderwater() public {
        uint256 initialBalance = 1000000e18;
        deal(address(sDai), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, spark.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, spark.id(), 100 ether);

        vault.rebalance(callData);

        // simulate 50% loss
        deal(address(weth), address(wethVault), 95 ether);

        uint256 totalBefore = vault.totalAssets();

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        vault.exitAllPositions(0);

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        assertApproxEqRel(vault.assetBalance(), totalBefore, 0.02e18, "vault sDai balance");
        assertEq(vault.totalCollateral(), 0, "vault collateral");
        assertEq(vault.totalDebt(), 0, "vault debt");
        assertEq(weth.balanceOf(address(vault)), 0, "weth balance");
        assertEq(vault.targetTokenInvestedAmount(), 0, "weth invested");
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralOnOneProtocolWhenInProfit() public {
        uint256 initialBalance = 1_000_000e18;
        deal(address(sDai), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, spark.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, spark.id(), 100 ether);

        vault.rebalance(callData);

        // simulate profit
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested.mulWadUp(1.5e18));

        assertEq(vault.getProfit(), 50 ether, "profit");

        uint256 totalBefore = vault.totalAssets();

        vault.exitAllPositions(0);

        assertApproxEqRel(vault.assetBalance(), totalBefore, 0.2e18, "vault sDai balance");
        assertEq(vault.totalCollateral(), 0, "vault collateral");
        assertEq(vault.totalDebt(), 0, "vault debt");
        assertEq(weth.balanceOf(address(vault)), 0, "weth balance");
        assertEq(vault.targetTokenInvestedAmount(), 0, "weth invested");
    }

    function test_repay() public {
        uint256 initialBalance = 100_000e18;
        uint256 borrowAmount = 2 ether;
        uint256 repayAmount = 1 ether;

        deal(address(sDai), address(vault), initialBalance);
        vault.supply(spark.id(), initialBalance);
        vault.borrow(spark.id(), borrowAmount);
        vault.repay(spark.id(), repayAmount);

        assertApproxEqAbs(spark.getDebt(address(vault)), borrowAmount - repayAmount, 1);
    }

    function test_withdraw() public {
        uint256 initialBalance = 10_000e18;
        deal(address(sDai), address(vault), initialBalance);
        vault.supply(spark.id(), initialBalance);

        uint256 withdrawAmount = 5_000e18;
        vault.withdraw(spark.id(), withdrawAmount);

        assertEq(vault.assetBalance(), withdrawAmount, "sdai balance");
        assertApproxEqAbs(spark.getCollateral(address(vault)), initialBalance - withdrawAmount, 1, "collateral");
    }

    function test_reallocate_FailsIfCallerIsNotKeeper() public {
        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.reallocate(0, new bytes[](0));
    }

    function test_reallocate() public {
        uint256 initialBalance = 1_000_000e18;
        deal(address(sDai), address(vault), initialBalance);

        uint256 totalDebt = 100 ether;

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, spark.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, spark.id(), totalDebt);

        vault.reallocate(50 ether, callData);

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral after");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "total debt after");

        _assertCollateralAndDebt(spark.id(), initialBalance, totalDebt);
    }

    ///////////////////////////////// INTERNAL METHODS /////////////////////////////////

    function _deployAndSetUpVault() internal {
        priceConverter = new SDaiWethPriceConverter();
        swapper = new SDaiWethSwapper();

        vault = new scSDAI(address(this), keeper, wethVault, priceConverter, swapper);

        vault.addAdapter(spark);

        // set vault eth balance to zero
        vm.deal(address(vault), 0);
        // set float percentage to 0 for most tests
        vault.setFloatPercentage(0);
        // assign keeper role to deployer
        vault.grantRole(vault.KEEPER_ROLE(), address(this));
    }

    function _assertCollateralAndDebt(uint256 _protocolId, uint256 _expectedCollateral, uint256 _expectedDebt)
        internal
    {
        uint256 collateral = vault.getCollateral(_protocolId);
        uint256 debt = vault.getDebt(_protocolId);
        string memory protocolName = _protocolIdToString(_protocolId);

        assertApproxEqAbs(collateral, _expectedCollateral, 1, string(abi.encodePacked("collateral on ", protocolName)));
        assertApproxEqAbs(debt, _expectedDebt, 1, string(abi.encodePacked("debt on ", protocolName)));
    }

    function _deposit(address _user, uint256 _amount) public returns (uint256 shares) {
        deal(address(sDai), _user, _amount);

        vm.startPrank(_user);
        sDai.approve(address(vault), _amount);
        shares = vault.deposit(_amount, _user);
        vm.stopPrank();
    }

    function _protocolIdToString(uint256 _protocolId) public view returns (string memory) {
        if (_protocolId == spark.id()) {
            return "Spark Lend";
        }

        revert("unknown protocol");
    }
}
