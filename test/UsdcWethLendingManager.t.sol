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
import {IEulerMarkets, IEulerEToken, IEulerDToken} from "lib/euler-interfaces/contracts/IEuler.sol";

import {Constants as C} from "../src/lib/Constants.sol";
import {ILendingPool} from "../src/interfaces/aave-v2/ILendingPool.sol";
import {IProtocolDataProvider} from "../src/interfaces/aave-v2/IProtocolDataProvider.sol";
import {sc4626} from "../src/sc4626.sol";
import {scUSDCv2} from "../src/steth/scUSDCv2.sol";
import {UsdcWethLendingManager} from "../src/steth/UsdcWethLendingManager.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {ISwapRouter} from "../src/interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import "../src/errors/scErrors.sol";

contract UsdcWethLendingManagerTest is Test {
    using FixedPointMathLib for uint256;

    event NewTargetLtvApplied(address indexed admin, uint256 newTargetLtv);
    event SlippageToleranceUpdated(address indexed admin, uint256 newSlippageTolerance);
    event EmergencyExitExecuted(
        address indexed admin, uint256 wethWithdrawn, uint256 debtRepaid, uint256 collateralReleased
    );
    event Reallocated(UsdcWethLendingManager.Protocol protocolId, bool isDownsize, uint256 collateral, uint256 debt);
    event Rebalanced(UsdcWethLendingManager.Protocol protocolId, uint256 supplied, bool leverageUp, uint256 debt);
    event ProfitSold(uint256 wethSold, uint256 usdcReceived);
    event EulerRewardsSold(uint256 eulerSold, uint256 usdcReceived);

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);

    WETH weth;
    ERC20 usdc;

    UsdcWethLendingManager lendingManager;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(16643381);

        usdc = ERC20(C.USDC);
        weth = WETH(payable(C.WETH));

        UsdcWethLendingManager.AaveV3 memory aaveV3 = UsdcWethLendingManager.AaveV3({
            pool: IPool(C.AAVE_POOL),
            poolDataProvider: IPoolDataProvider(C.AAVE_POOL_DATA_PROVIDER),
            aUsdc: IAToken(C.AAVE_AUSDC_TOKEN),
            varDWeth: ERC20(C.AAVAAVE_VAR_DEBT_WETH_TOKEN)
        });

        UsdcWethLendingManager.Euler memory euler = UsdcWethLendingManager.Euler({
            protocol: C.EULER_PROTOCOL,
            markets: IEulerMarkets(C.EULER_MARKETS),
            eUsdc: IEulerEToken(C.EULER_EUSDC_TOKEN),
            dWeth: IEulerDToken(C.EULER_DWETH_TOKEN),
            rewardsToken: ERC20(C.EULER_REWARDS_TOKEN)
        });

        UsdcWethLendingManager.AaveV2 memory aaveV2 = UsdcWethLendingManager.AaveV2({
            pool: ILendingPool(C.AAVE_V2_LENDING_POOL),
            protocolDataProvider: IProtocolDataProvider(C.AAVE_V2_PROTOCOL_DATA_PROVIDER),
            aUsdc: ERC20(C.AAVE_V2_AUSDC_TOKEN),
            varDWeth: ERC20(C.AAVE_V2_VAR_DEBT_WETH_TOKEN)
        });

        lendingManager = new UsdcWethLendingManager(usdc, weth, aaveV3, aaveV2, euler);
    }

    /// #getMaxLtv ///

    function test_getMaxLtv_AaveV3() public {
        uint256 maxLtv = lendingManager.getMaxLtv(UsdcWethLendingManager.Protocol.AAVE_V3);

        assertEq(maxLtv, 0.74e18, "max ltv");
    }

    function test_getMaxLtv_AaveV2() public {
        uint256 maxLtv = lendingManager.getMaxLtv(UsdcWethLendingManager.Protocol.AAVE_V2);

        assertEq(maxLtv, 0.8e18, "max ltv");
    }

    function test_getMaxLtv_Euler() public {
        uint256 maxLtv = lendingManager.getMaxLtv(UsdcWethLendingManager.Protocol.EULER);

        assertEq(maxLtv, 0.819e18, "max ltv");
    }

    /// #getLendingPositionsInfo ///

    function test_getLendingPositionsInfo_ReturnsInfoOnOneProtocol() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(lendingManager), initialBalance);
        vm.startPrank(address(lendingManager));

        usdc.approve(address(lendingManager.aaveV3Pool()), initialBalance);
        lendingManager.supply(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance);
        lendingManager.borrow(UsdcWethLendingManager.Protocol.AAVE_V3, initialDebt);

        UsdcWethLendingManager.Protocol[] memory protocolIds = new UsdcWethLendingManager.Protocol[](1);
        protocolIds[0] = UsdcWethLendingManager.Protocol.AAVE_V3;

        UsdcWethLendingManager.LendingPositionInfo[] memory positions =
            lendingManager.getLendingPositionsInfo(protocolIds, address(lendingManager));

        assertEq(positions.length, 1, "positions info length");
        assertEq(uint8(positions[0].protocolId), uint8(UsdcWethLendingManager.Protocol.AAVE_V3), "protocolId");
        assertEq(positions[0].collateral, initialBalance, "supplyAmount");
        assertEq(positions[0].debt, initialDebt, "borrowAmount");
    }

    function test_getLendingPositionsInfo_ReturnsInfoOnMultipleProtocols() public {
        uint256 initialBalancePerProtocol = 500_000e6;
        uint256 initialDebtPerProtocol = 100 ether;
        deal(address(usdc), address(lendingManager), initialBalancePerProtocol * 3);
        vm.startPrank(address(lendingManager));

        usdc.approve(address(lendingManager.aaveV3Pool()), initialBalancePerProtocol);
        lendingManager.supply(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalancePerProtocol);
        lendingManager.borrow(UsdcWethLendingManager.Protocol.AAVE_V3, initialDebtPerProtocol);

        usdc.approve(address(lendingManager.aaveV2Pool()), initialBalancePerProtocol);
        lendingManager.supply(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalancePerProtocol);
        lendingManager.borrow(UsdcWethLendingManager.Protocol.AAVE_V2, initialDebtPerProtocol);

        usdc.approve(address(lendingManager.eulerProtocol()), initialBalancePerProtocol);
        lendingManager.eulerMarkets().enterMarket(0, address(usdc));
        lendingManager.supply(UsdcWethLendingManager.Protocol.EULER, initialBalancePerProtocol);
        lendingManager.borrow(UsdcWethLendingManager.Protocol.EULER, initialDebtPerProtocol);

        UsdcWethLendingManager.Protocol[] memory protocolIds = new UsdcWethLendingManager.Protocol[](3);
        protocolIds[0] = UsdcWethLendingManager.Protocol.AAVE_V3;
        protocolIds[1] = UsdcWethLendingManager.Protocol.EULER;
        protocolIds[2] = UsdcWethLendingManager.Protocol.AAVE_V2;

        UsdcWethLendingManager.LendingPositionInfo[] memory positions =
            lendingManager.getLendingPositionsInfo(protocolIds, address(lendingManager));

        assertEq(positions.length, 3, "positions info length");
        assertEq(
            uint8(positions[0].protocolId), uint8(UsdcWethLendingManager.Protocol.AAVE_V3), "protocolId not AAVE_V3"
        );
        assertApproxEqAbs(positions[0].collateral, initialBalancePerProtocol, 1, "aave v3 collateral");
        assertApproxEqAbs(positions[0].debt, initialDebtPerProtocol, 1, "aave v3 debt");

        assertEq(uint8(positions[1].protocolId), uint8(UsdcWethLendingManager.Protocol.EULER), "protocolId not EULER");
        assertApproxEqAbs(positions[1].collateral, initialBalancePerProtocol, 1, "euler collateral");
        assertApproxEqAbs(positions[1].debt, initialDebtPerProtocol, 1, "euler debt");

        assertEq(
            uint8(positions[2].protocolId), uint8(UsdcWethLendingManager.Protocol.AAVE_V2), "protocolId not AAVE_V2"
        );
        assertApproxEqAbs(positions[2].collateral, initialBalancePerProtocol, 1, "aave v2 collateral");
        assertApproxEqAbs(positions[2].debt, initialDebtPerProtocol, 1, "aave v2 debt");
    }

    function test_getLendingPositionsInfo_WorksWhenProtocolRequestedIsNotUsed() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(lendingManager), initialBalance);
        vm.startPrank(address(lendingManager));

        usdc.approve(address(lendingManager.eulerProtocol()), initialBalance);
        lendingManager.eulerMarkets().enterMarket(0, address(usdc));
        lendingManager.supply(UsdcWethLendingManager.Protocol.EULER, initialBalance);
        lendingManager.borrow(UsdcWethLendingManager.Protocol.EULER, initialDebt);

        // AAVE V3 is not used
        UsdcWethLendingManager.Protocol[] memory protocolIds = new UsdcWethLendingManager.Protocol[](2);
        protocolIds[0] = UsdcWethLendingManager.Protocol.AAVE_V3;
        protocolIds[1] = UsdcWethLendingManager.Protocol.EULER;

        UsdcWethLendingManager.LendingPositionInfo[] memory positions =
            lendingManager.getLendingPositionsInfo(protocolIds, address(lendingManager));

        assertEq(positions.length, 2, "positions info length");
        assertEq(
            uint8(positions[0].protocolId), uint8(UsdcWethLendingManager.Protocol.AAVE_V3), "protocolId not AAVE_V3"
        );
        assertEq(positions[0].collateral, 0, "aave v3 collateral not 0");
        assertEq(positions[0].debt, 0, "aave v3 debt not 0");

        assertEq(uint8(positions[1].protocolId), uint8(UsdcWethLendingManager.Protocol.EULER), "protocolId not EULER");
        assertApproxEqAbs(positions[1].collateral, initialBalance, 1, "euler collateral");
        assertApproxEqAbs(positions[1].debt, initialDebt, 1, "euler debt");
    }
}
