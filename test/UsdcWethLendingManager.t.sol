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
import {UsdcWethLendingManager} from "../src/steth/UsdcWethLendingManager.sol";

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

        lendingManager = new UsdcWethLendingManager(usdc, weth, C.ZERO_EX_ROUTER, aaveV3, aaveV2, euler);
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

    /// #getCollateralAndDebtPositions ///

    function test_getCollateralAndDebtPositions_ReturnsInfoOnOneProtocol() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(lendingManager), initialBalance);
        vm.startPrank(address(lendingManager));

        usdc.approve(address(lendingManager.aaveV3Pool()), initialBalance);
        lendingManager.supply(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance);
        lendingManager.borrow(UsdcWethLendingManager.Protocol.AAVE_V3, initialDebt);

        UsdcWethLendingManager.Protocol[] memory protocolIds = new UsdcWethLendingManager.Protocol[](1);
        protocolIds[0] = UsdcWethLendingManager.Protocol.AAVE_V3;

        (uint256[] memory collateralPositions, uint256[] memory debtPositions) =
            lendingManager.getCollateralAndDebtPositions(protocolIds, address(lendingManager));

        assertEq(collateralPositions.length, 1, "collateral positions length");
        assertEq(debtPositions.length, 1, "debt positions length");
        assertEq(collateralPositions[0], initialBalance, "collateral");
        assertEq(debtPositions[0], initialDebt, "debt");
    }

    function test_getCollateralAndDebtPositions_ReturnsInfoOnMultipleProtocols() public {
        uint256 aaveV3Deposit = 500_000e6;
        uint256 aaveV3Loan = 100 ether;
        uint256 aaveV2Deposit = 400_000e6;
        uint256 aaveV2Loan = 80 ether;
        uint256 eulerDeposit = 300_000e6;
        uint256 eulerLoan = 60 ether;
        deal(address(usdc), address(lendingManager), aaveV3Deposit + aaveV2Deposit + eulerDeposit);
        vm.startPrank(address(lendingManager));

        usdc.approve(address(lendingManager.aaveV3Pool()), aaveV3Deposit);
        lendingManager.supply(UsdcWethLendingManager.Protocol.AAVE_V3, aaveV3Deposit);
        lendingManager.borrow(UsdcWethLendingManager.Protocol.AAVE_V3, aaveV3Loan);

        usdc.approve(address(lendingManager.aaveV2Pool()), aaveV2Deposit);
        lendingManager.supply(UsdcWethLendingManager.Protocol.AAVE_V2, aaveV2Deposit);
        lendingManager.borrow(UsdcWethLendingManager.Protocol.AAVE_V2, aaveV2Loan);

        usdc.approve(address(lendingManager.eulerProtocol()), eulerDeposit);
        lendingManager.eulerMarkets().enterMarket(0, address(usdc));
        lendingManager.supply(UsdcWethLendingManager.Protocol.EULER, eulerDeposit);
        lendingManager.borrow(UsdcWethLendingManager.Protocol.EULER, eulerLoan);

        UsdcWethLendingManager.Protocol[] memory protocolIds = new UsdcWethLendingManager.Protocol[](3);
        protocolIds[0] = UsdcWethLendingManager.Protocol.AAVE_V3;
        protocolIds[1] = UsdcWethLendingManager.Protocol.EULER;
        protocolIds[2] = UsdcWethLendingManager.Protocol.AAVE_V2;

        (uint256[] memory collateralPositions, uint256[] memory debtPositions) =
            lendingManager.getCollateralAndDebtPositions(protocolIds, address(lendingManager));

        assertEq(collateralPositions.length, 3, "collateral positions length");
        assertEq(debtPositions.length, 3, "debt positions length");

        assertApproxEqAbs(collateralPositions[0], aaveV3Deposit, 1, "aave v3 collateral");
        assertApproxEqAbs(debtPositions[0], aaveV3Loan, 1, "aave v3 debt");

        assertApproxEqAbs(collateralPositions[1], eulerDeposit, 1, "euler collateral");
        assertApproxEqAbs(debtPositions[1], eulerLoan, 1, "euler debt");

        assertApproxEqAbs(collateralPositions[2], aaveV2Deposit, 1, "aave v2 collateral");
        assertApproxEqAbs(debtPositions[2], aaveV2Loan, 1, "aave v2 debt");
    }

    function test_getCollateralAndDebtPositions_WorksWhenProtocolRequestedIsNotUsed() public {
        uint256 eulerDeposit = 1_000_000e6;
        uint256 eulerDebt = 100 ether;
        deal(address(usdc), address(lendingManager), eulerDeposit);
        vm.startPrank(address(lendingManager));

        usdc.approve(address(lendingManager.eulerProtocol()), eulerDeposit);
        lendingManager.eulerMarkets().enterMarket(0, address(usdc));
        lendingManager.supply(UsdcWethLendingManager.Protocol.EULER, eulerDeposit);
        lendingManager.borrow(UsdcWethLendingManager.Protocol.EULER, eulerDebt);

        // AAVE V3 is not used
        UsdcWethLendingManager.Protocol[] memory protocolIds = new UsdcWethLendingManager.Protocol[](2);
        protocolIds[0] = UsdcWethLendingManager.Protocol.AAVE_V3;
        protocolIds[1] = UsdcWethLendingManager.Protocol.EULER;

        (uint256[] memory collateralPositions, uint256[] memory debtPositions) =
            lendingManager.getCollateralAndDebtPositions(protocolIds, address(lendingManager));

        assertEq(collateralPositions.length, 2, "positions info length");
        assertEq(debtPositions.length, 2, "positions info length");

        assertEq(collateralPositions[0], 0, "aave v3 collateral not 0");
        assertEq(debtPositions[0], 0, "aave v3 debt not 0");

        assertApproxEqAbs(collateralPositions[1], eulerDeposit, 1, "euler collateral");
        assertApproxEqAbs(debtPositions[1], eulerDebt, 1, "euler debt");
    }
}
