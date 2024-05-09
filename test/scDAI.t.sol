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

import {Constants as C} from "../src/lib/Constants.sol";
import {ILendingPool} from "../src/interfaces/aave-v2/ILendingPool.sol";
import {IProtocolDataProvider} from "../src/interfaces/aave-v2/IProtocolDataProvider.sol";
import {IAdapter} from "../src/steth/IAdapter.sol";
import {SparkScDaiAdapter} from "../src/steth/scDai-adapters/SparkScDaiAdapter.sol";
import {scDAI} from "../src/steth/scDAI.sol";

import {scWETH} from "../src/steth/scWETH.sol";
import {ISwapRouter} from "../src/interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {PriceConverter} from "../src/steth/PriceConverter.sol";
import {Swapper} from "../src/steth/Swapper.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {IProtocolFeesCollector} from "../src/interfaces/balancer/IProtocolFeesCollector.sol";
import "../src/errors/scErrors.sol";
import {FaultyAdapter} from "./mocks/adapters/FaultyAdapter.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

contract scDAITest is Test {
    using Address for address;
    using FixedPointMathLib for uint256;

    event UsdcToEthPriceFeedUpdated(address indexed admin, address newPriceFeed);
    event ProtocolAdapterAdded(address indexed admin, uint256 adapterId, address adapter);
    event ProtocolAdapterRemoved(address indexed admin, uint256 adapterId);
    event NewTargetLtvApplied(address indexed admin, uint256 newTargetLtv);
    event SlippageToleranceUpdated(address indexed admin, uint256 newSlippageTolerance);
    event EmergencyExitExecuted(
        address indexed admin, uint256 wethWithdrawn, uint256 debtRepaid, uint256 collateralReleased
    );
    event Reallocated();
    event Rebalanced(uint256 totalCollateral, uint256 totalDebt, uint256 floatBalance);
    event ProfitSold(uint256 wethSold, uint256 usdcReceived);
    event TokenSwapped(address token, uint256 amountSold, uint256 usdcReceived);
    event Supplied(uint256 adapterId, uint256 amount);
    event Borrowed(uint256 adapterId, uint256 amount);
    event Repaid(uint256 adapterId, uint256 amount);
    event Withdrawn(uint256 adapterId, uint256 amount);
    event Disinvested(uint256 wethAmount);
    event RewardsClaimed(uint256 adapterId);
    event SwapperUpdated(address indexed admin, Swapper newSwapper);

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);

    WETH weth;
    ERC20 dai;

    scWETH wethVault;
    scDAI vault;

    SparkScDaiAdapter spark;
    Swapper swapper;
    PriceConverter priceConverter;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(19832667);

        dai = ERC20(C.SDAI);
        weth = WETH(payable(C.WETH));
        spark = new SparkScDaiAdapter();

        _deployScWeth();
        _deployAndSetUpVault();
    }

    /// #constructor ///

    function test_constructor() public {
        assertEq(address(vault.asset()), C.SDAI);
        assertEq(address(vault.scWETH()), address(wethVault), "weth vault");
        assertEq(address(vault.priceConverter()), address(priceConverter), "price converter");
        assertEq(address(vault.swapper()), address(swapper), "swapper");

        assertEq(weth.allowance(address(vault), address(vault.scWETH())), type(uint256).max, "scWETH allowance");
    }

    function test_rebalance() public {
        uint256 initialBalance = 1_000_000e18;
        uint256 initialDebt = 100 ether;
        deal(address(dai), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scDAI.supply.selector, spark.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scDAI.borrow.selector, spark.id(), initialDebt);

        vault.rebalance(callData);

        assertEq(vault.totalDebt(), initialDebt, "total debt");
        assertEq(vault.totalCollateral(), initialBalance, "total collateral");

        _assertCollateralAndDebt(spark.id(), initialBalance, initialDebt);

        assertEq(wethVault.balanceOf(address(vault)), initialDebt, "scETH shares");
    }

    function testFuzz_rebalance(uint256 supplyOnSpark, uint256 borrowOnSpark) public {
        uint256 floatPercentage = 0.01e18;
        vault.setFloatPercentage(floatPercentage);

        supplyOnSpark = bound(supplyOnSpark, 100e18, 1_000_000e18);

        uint256 initialBalance = supplyOnSpark.divWadDown(1e18 - floatPercentage);
        uint256 minFloat = supplyOnSpark.mulWadDown(floatPercentage);

        borrowOnSpark = bound(
            borrowOnSpark,
            1e10,
            priceConverter.sDaiToEth(supplyOnSpark).mulWadDown(spark.getMaxLtv() - 0.005e18) // -0.5% to avoid borrowing at max ltv
        );

        deal(address(dai), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scDAI.supply.selector, spark.id(), supplyOnSpark);
        callData[1] = abi.encodeWithSelector(scDAI.borrow.selector, spark.id(), borrowOnSpark);

        vault.rebalance(callData);

        _assertCollateralAndDebt(spark.id(), supplyOnSpark, borrowOnSpark);
        assertApproxEqAbs(vault.totalAssets(), initialBalance, 1e10, "total assets");
        assertApproxEqAbs(vault.sDaiBalance(), minFloat, vault.totalAssets().mulWadDown(floatPercentage), "float");
    }

    function test_disinvest() public {
        uint256 initialBalance = 1_000_000e18;
        uint256 initialDebt = 100 ether;
        deal(address(dai), address(vault), initialBalance);
        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scDAI.supply.selector, spark.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scDAI.borrow.selector, spark.id(), initialDebt);
        vault.rebalance(callData);

        uint256 disinvestAmount = vault.wethInvested() / 2;
        vm.expectEmit(true, true, true, true);
        emit Disinvested(disinvestAmount);

        vault.disinvest(disinvestAmount);

        assertEq(weth.balanceOf(address(vault)), disinvestAmount, "weth balance");
        assertEq(vault.wethInvested(), initialDebt - disinvestAmount, "weth invested");
    }

    function test_sellProfit() public {
        uint256 initialBalance = 100000e18;
        uint256 initialDebt = 10 ether;
        deal(address(dai), address(vault), initialBalance);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scDAI.supply.selector, spark.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scDAI.borrow.selector, spark.id(), initialDebt);

        vault.rebalance(callData);

        // add 100% profit to the weth vault
        uint256 initialWethInvested = vault.wethInvested();
        deal(address(weth), address(wethVault), initialWethInvested * 2);

        uint256 daiBalanceBefore = vault.sDaiBalance();
        uint256 profit = vault.getProfit();

        vm.prank(keeper);
        bytes memory swapData =
            hex"878863a496bdd049928fadd44bb50b83ba8d5e2715a135b8190596ac8be280b0cac2987700000000000000000000000000000000000000000000000000000000000000c00000000000000000000000000000000000000000000000000000000000000100000000000000000000000000c7183455a4c133ae270771860664b6b7ec320bb10000000000000000000000000000000000000000000005d25bb32f6753f62d8a000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000000086c6966692d617069000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002a307830303030303030303030303030303030303030303030303030303030303030303030303030303030000000000000000000000000000000000000000000000000000000000000000000001111111254eeb25477b68fb85ed929f73a9605820000000000000000000000001111111254eeb25477b68fb85ed929f73a960582000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000083f20f44975d03b1b09e64809b757c47f942beea0000000000000000000000000000000000000000000000008ac7230489e8000000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000030812aa3caf000000000000000000000000e37e799d5077682fa0a244d46e5649f71457bd09000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000083f20f44975d03b1b09e64809b757c47f942beea000000000000000000000000e37e799d5077682fa0a244d46e5649f71457bd090000000000000000000000001231deb6f5749ef6ce6943a275a1d3e7486f4eae0000000000000000000000000000000000000000000000008ac7230489e800000000000000000000000000000000000000000000000005d25bb32f6753f62d8a0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000001600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000017f0000000000000000000000000000000000000000000001610001330000e900a007e5c0d20000000000000000000000000000000000000000000000c500005500004f02a000000000000000000000000000000000000000000000000000000006e1b5c60fee63c1e50088e6a0c2ddd26feeb64f039a2c41296fcb3f5640c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200a0fd53121f512083f20f44975d03b1b09e64809b757c47f942beea6b175474e89094c44da98b954eedeac495271d0f00046e553f650000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e37e799d5077682fa0a244d46e5649f71457bd0900a0f2fa6b6683f20f44975d03b1b09e64809b757c47f942beea0000000000000000000000000000000000000000000005d9d8f1d59771f8b38f00000000000000004019c350baac31a980a06c4eca2783f20f44975d03b1b09e64809b757c47f942beea1111111254eeb25477b68fb85ed929f73a960582002a94d114000000000000000000000000000000000000000000000000";
        vault.sellProfit(0, swapData);

        uint256 expectedDaiBalance = daiBalanceBefore + priceConverter.ethTosDai(profit);
        _assertCollateralAndDebt(spark.id(), initialBalance, initialDebt);
        assertApproxEqRel(vault.sDaiBalance(), expectedDaiBalance, 0.01e18, "dai balance");
        assertApproxEqRel(vault.wethInvested(), initialWethInvested, 0.001e18, "sold more than actual profit");
    }

    function test_lifi() public {
        console.log(address(this));
        uint256 amount = 10000000000000000000;
        address lifi = 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE;

        deal(C.WETH, address(this), amount);

        ERC20(C.WETH).approve(lifi, amount);

        console.log("dai balance", ERC20(C.SDAI).balanceOf(address(this)));
        console.log("weth balance", ERC20(C.WETH).balanceOf(address(this)));
        console.log("eth balance", address(this).balance);

        console.log("-----------------------");

        bytes memory swapData =
            hex"878863a4a02f2e4a3e115e3d5285ade4a113cac81309fa4b93515ebe8d5a87760d8432d800000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000001000000000000000000000000007fa9385be102ac3eac297483dd6233d62b3e14960000000000000000000000000000000000000000000005d0ccd1235c457d5c2b000000000000000000000000000000000000000000000000000000000000016000000000000000000000000000000000000000000000000000000000000000086c6966692d617069000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002a307830303030303030303030303030303030303030303030303030303030303030303030303030303030000000000000000000000000000000000000000000000000000000000000000000001111111254eeb25477b68fb85ed929f73a9605820000000000000000000000001111111254eeb25477b68fb85ed929f73a960582000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000083f20f44975d03b1b09e64809b757c47f942beea0000000000000000000000000000000000000000000000008ac7230489e8000000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000030812aa3caf000000000000000000000000e37e799d5077682fa0a244d46e5649f71457bd09000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200000000000000000000000083f20f44975d03b1b09e64809b757c47f942beea000000000000000000000000e37e799d5077682fa0a244d46e5649f71457bd090000000000000000000000001231deb6f5749ef6ce6943a275a1d3e7486f4eae0000000000000000000000000000000000000000000000008ac7230489e800000000000000000000000000000000000000000000000005d0ccd1235c457d5c2a0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000001600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000017f0000000000000000000000000000000000000000000001610001330000e900a007e5c0d20000000000000000000000000000000000000000000000c500005500004f02a000000000000000000000000000000000000000000000000000000006dfdda0d1ee63c1e50088e6a0c2ddd26feeb64f039a2c41296fcb3f5640c02aaa39b223fe8d0a0e5c4f27ead9083c756cc200a0fd53121f512083f20f44975d03b1b09e64809b757c47f942beea6b175474e89094c44da98b954eedeac495271d0f00046e553f650000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e37e799d5077682fa0a244d46e5649f71457bd0900a0f2fa6b6683f20f44975d03b1b09e64809b757c47f942beea0000000000000000000000000000000000000000000005d8480ea6c113ab03de00000000000000004013da5f59051fc280a06c4eca2783f20f44975d03b1b09e64809b757c47f942beea1111111254eeb25477b68fb85ed929f73a960582002a94d114000000000000000000000000000000000000000000000000";

        lifi.functionCall(swapData);

        console.log("dai balance", ERC20(C.SDAI).balanceOf(address(this)));
        console.log("weth balance", ERC20(C.WETH).balanceOf(address(this)));
        console.log("eth balance", address(this).balance);
    }

    function test_withdraw() public {
        uint256 initialBalance = 1_000_000e18;
        deal(address(dai), alice, initialBalance);

        vm.startPrank(alice);
        dai.approve(address(vault), initialBalance);
        vault.deposit(initialBalance, alice);
        vm.stopPrank();

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scDAI.supply.selector, spark.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scDAI.borrow.selector, spark.id(), 100 ether);

        vault.rebalance(callData);

        uint256 withdrawAmount = vault.convertToAssets(vault.balanceOf(alice));
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(dai.balanceOf(alice), withdrawAmount, "alice asset balance");
    }

    function testFuzz_withdraw(uint256 _amount, uint256 _withdrawAmount) public {
        _amount = 36072990718134180857610733478 * 1e12;
        _withdrawAmount = 0;
        _amount = bound(_amount, 1e18, 10_000_000e18); // upper limit constrained by weth available on aave v3
        deal(address(dai), alice, _amount);
        // console2.log("amount", _amount);

        vm.startPrank(alice);
        dai.approve(address(vault), type(uint256).max);
        vault.deposit(_amount, alice);
        vm.stopPrank();

        uint256 borrowAmount = priceConverter.sDaiToEth(_amount.mulWadDown(0.7e18));

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scDAI.supply.selector, spark.id(), _amount);
        callData[1] = abi.encodeWithSelector(scDAI.borrow.selector, spark.id(), borrowAmount);

        vault.rebalance(callData);

        uint256 total = vault.totalAssets();
        _withdrawAmount = bound(_withdrawAmount, 1e18, total);
        vm.startPrank(alice);
        vault.withdraw(_withdrawAmount, alice, alice);

        assertApproxEqAbs(vault.totalAssets(), total - _withdrawAmount, 0.0001e18, "total assets");
        assertApproxEqAbs(dai.balanceOf(alice), _withdrawAmount, 0.01e18, "usdc balance");
    }

    function testFuzz_withdraw_whenInProfit(uint256 _amount, uint256 _withdrawAmount) public {
        _amount = 0;
        _amount = bound(_amount, 1e18, 10_000_000e18); // upper limit constrained by weth available on aave v3
        deal(address(dai), alice, _amount);
        console2.log("amount", _amount);

        vm.startPrank(alice);
        dai.approve(address(vault), type(uint256).max);
        vault.deposit(_amount, alice);
        vm.stopPrank();

        uint256 borrowAmount = priceConverter.sDaiToEth(_amount.mulWadDown(0.7e18));

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scDAI.supply.selector, spark.id(), _amount);
        callData[1] = abi.encodeWithSelector(scDAI.borrow.selector, spark.id(), borrowAmount);

        vault.rebalance(callData);

        // add 1% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested.mulWadUp(1.01e18));

        uint256 total = vault.totalAssets();
        _withdrawAmount = bound(_withdrawAmount, 1e18, total);
        vm.startPrank(alice);
        vault.withdraw(_withdrawAmount, alice, alice);

        assertApproxEqAbs(vault.totalAssets(), total - _withdrawAmount, total.mulWadDown(0.001e18), "total assets");
        assertApproxEqAbs(dai.balanceOf(alice), _withdrawAmount, _amount.mulWadDown(0.001e18), "dai balance");
    }

    ///////////////////////////////// INTERNAL METHODS /////////////////////////////////

    function _deployScWeth() internal {
        scWETH.ConstructorParams memory scWethParams = scWETH.ConstructorParams({
            admin: address(this),
            keeper: keeper,
            targetLtv: 0.7e18,
            slippageTolerance: 0.99e18,
            aavePool: IPool(C.AAVE_V3_POOL),
            aaveAwstEth: IAToken(C.AAVE_V3_AWSTETH_TOKEN),
            aaveVarDWeth: ERC20(C.AAVE_V3_VAR_DEBT_WETH_TOKEN),
            curveEthStEthPool: ICurvePool(C.CURVE_ETH_STETH_POOL),
            stEth: ILido(C.STETH),
            wstEth: IwstETH(C.WSTETH),
            weth: WETH(payable(C.WETH)),
            stEthToEthPriceFeed: AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED),
            balancerVault: IVault(C.BALANCER_VAULT)
        });

        wethVault = new scWETH(scWethParams);
    }

    function _deployAndSetUpVault() internal {
        priceConverter = new PriceConverter(address(this));
        swapper = new Swapper();

        vault = new scDAI(address(this), keeper, wethVault, priceConverter, swapper);

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

    function _protocolIdToString(uint256 _protocolId) public view returns (string memory) {
        if (_protocolId == spark.id()) {
            return "Spark Lend";
        }

        revert("unknown protocol");
    }
}
