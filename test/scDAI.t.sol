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

contract scDAITest is Test {
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
        vm.rollFork(19774188);

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
        vault.sellProfit(0);

        uint256 expectedDaiBalance = daiBalanceBefore + priceConverter.ethTosDai(profit);
        _assertCollateralAndDebt(spark.id(), initialBalance, initialDebt);
        assertApproxEqRel(vault.sDaiBalance(), expectedDaiBalance, 0.01e18, "dai balance");
        assertApproxEqRel(vault.wethInvested(), initialWethInvested, 0.001e18, "sold more than actual profit");
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
