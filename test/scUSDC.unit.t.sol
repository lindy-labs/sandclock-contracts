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
import "../src/errors/scErrors.sol";

import {MockWETH} from "./mock/MockWETH.sol";
import {MockUSDC} from "./mock/MockUSDC.sol";
import {MockAavePool} from "./mock/aave-v3/MockAavePool.sol";
import {MockAavePoolDataProvider} from "./mock/aave-v3/MockAavePoolDataProvider.sol";
import {MockAUsdc} from "./mock/aave-v3/MockAUsdc.sol";
import {MockVarDebtWETH} from "./mock/aave-v3/MockVarDebtWETH.sol";
import {MockAwstETH} from "./mock/aave-v3/MockAwstETH.sol";
import {MockStETH} from "./mock/lido/MockStETH.sol";
import {MockWstETH} from "./mock/lido/MockWstETH.sol";
import {MockChainlinkPriceFeed} from "./mock/chainlink/MockChainlinkPriceFeed.sol";
import {MockCurvePool} from "./mock/curve/MockCurvePool.sol";
import {MockBalancerVault} from "./mock/balancer/MockBalancerVault.sol";
import {MockSwapRouter} from "./mock/uniswap/MockSwapRouter.sol";

contract scUSDCTest is Test {
    using FixedPointMathLib for uint256;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);

    scUSDC vault;
    scWETH wethVault;

    MockUSDC usdc = new MockUSDC();
    MockWETH weth = new MockWETH();

    IPoolDataProvider aavePoolDataProvider = new MockAavePoolDataProvider(address(usdc), address(weth));
    MockAavePool aavePool = new MockAavePool();
    MockAUsdc aaveAUsdc = new MockAUsdc(aavePool, usdc);
    MockVarDebtWETH aaveVarDWeth = new MockVarDebtWETH(aavePool, weth);
    MockStETH stEth = new MockStETH();
    MockWstETH wstEth = new MockWstETH(stEth);
    MockAwstETH aaveAWstEth = new MockAwstETH(aavePool, wstEth);

    MockCurvePool curveEthStEthPool = new MockCurvePool(stEth);
    MockChainlinkPriceFeed stEthToEthPriceFeed = new MockChainlinkPriceFeed(address(stEth), address(weth), 1e18);
    MockChainlinkPriceFeed usdcToEthPriceFeed = new MockChainlinkPriceFeed(address(usdc), address(weth), 0.001e18);
    MockBalancerVault balancerVault = new MockBalancerVault(weth);
    MockSwapRouter uniswapRouter = new MockSwapRouter();

    function setUp() public {
        scWETH.ConstructorParams memory scWethParams = scWETH.ConstructorParams({
            admin: address(this),
            keeper: keeper,
            targetLtv: 0.7e18,
            slippageTolerance: 0.99e18,
            aavePool: aavePool,
            aaveAwstEth: IAToken(address(aaveAWstEth)),
            aaveVarDWeth: ERC20(address(aaveVarDWeth)),
            curveEthStEthPool: curveEthStEthPool,
            stEth: ILido(address(stEth)),
            wstEth: IwstETH(address(wstEth)),
            weth: WETH(payable(weth)),
            stEthToEthPriceFeed: stEthToEthPriceFeed,
            balancerVault: balancerVault
        });

        wethVault = new scWETH(scWethParams);

        scUSDC.ConstructorParams memory scUsdcParams = scUSDC.ConstructorParams({
            admin: address(this),
            keeper: keeper,
            scWETH: wethVault,
            usdc: usdc,
            weth: WETH(payable(weth)),
            aavePool: aavePool,
            aavePoolDataProvider: aavePoolDataProvider,
            aaveAUsdc: IAToken(address(aaveAUsdc)),
            aaveVarDWeth: ERC20(address(aaveVarDWeth)),
            uniswapSwapRouter: uniswapRouter,
            chainlinkUsdcToEthPriceFeed: usdcToEthPriceFeed,
            balancerVault: balancerVault
        });

        vault = new scUSDC(scUsdcParams);

        weth.mint(address(aavePool), 100e18);
    }

    function test_rebalance() public {
        uint256 amount = 10000e6;
        deal(address(usdc), address(alice), amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);

        vault.deposit(amount, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vault.rebalance();

        assertApproxEqAbs(vault.getCollateral(), amount.mulWadDown(0.99e18), 1, "collateral");
        assertEq(vault.getDebt(), 6.435e18, "debt");
        assertEq(vault.getUsdcBalance(), amount.mulWadUp(vault.floatPercentage()), "float");
        assertApproxEqAbs(vault.totalAssets(), amount, 1, "total assets");
    }

    function test_withdraw() public {
        uint256 depositAmount = 10000e6;
        deal(address(usdc), address(alice), depositAmount);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);

        vault.deposit(depositAmount, alice);
        vm.stopPrank();

        vm.prank(keeper);
        vault.rebalance();

        vm.startPrank(alice);
        uint256 withdrawAmount = 1000e6;
        vault.withdraw(1000e6, alice, alice);
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), withdrawAmount, "alice usdc balance");
        assertApproxEqAbs(vault.getCollateral(), (depositAmount - withdrawAmount).mulWadDown(0.99e18), 1, "collateral"); // - float
        assertEq(vault.getDebt(), uint256(6.435e18).mulWadDown(0.9e18), "debt");
        assertEq(vault.getUsdcBalance(), (depositAmount - withdrawAmount).mulWadUp(vault.floatPercentage()), "float");
        assertApproxEqAbs(vault.totalAssets(), (depositAmount - withdrawAmount), 1, "total assets");
    }
}
