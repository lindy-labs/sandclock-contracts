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

contract scUSDCv2Test is Test {
    using FixedPointMathLib for uint256;

    event NewTargetLtvApplied(address indexed admin, uint256 newTargetLtv);
    event SlippageToleranceUpdated(address indexed admin, uint256 newSlippageTolerance);
    event EmergencyExitExecuted(
        address indexed admin, uint256 wethWithdrawn, uint256 debtRepaid, uint256 collateralReleased
    );
    event Reallocated(UsdcWethLendingManager.Protocol protocolId, bool isDownsize, uint256 collateral, uint256 debt);
    event Rebalanced(UsdcWethLendingManager.Protocol protocolId, uint256 supplied, bool leverageUp, uint256 debt);
    event ProfitSold(uint256 wethSold, uint256 usdcReceived);

    uint256 mainnetFork;
    uint256 constant ethWstEthMaxLtv = 0.7735e18;
    uint256 constant slippageTolerance = 0.999e18;
    uint256 constant flashLoanLtv = 0.5e18;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);

    scUSDCv2 vault;
    scWETH wethVault;

    WETH weth;
    ERC20 usdc;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(16643381);

        usdc = ERC20(C.USDC);
        weth = WETH(payable(C.WETH));

        scWETH.ConstructorParams memory scWethParams = scWETH.ConstructorParams({
            admin: address(this),
            keeper: keeper,
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

        scUSDCv2.ConstructorParams memory params = _createDefaultUsdcVaultConstructorParams(wethVault);

        vault = new scUSDCv2(params);

        // set vault eth balance to zero
        vm.deal(address(vault), 0);
        // set float percentage to 0 for most tests
        vault.setFloatPercentage(0);
    }

    /// #constructor ///

    function test_constructor() public {
        assertEq(address(vault.asset()), address(usdc));
        assertEq(address(vault.scWETH()), address(wethVault));

        // check approvals
        assertEq(usdc.allowance(address(vault), address(vault.aavePool())), type(uint256).max, "usdc->aave allowance");
        assertEq(
            usdc.allowance(address(vault), address(vault.eulerProtocol())), type(uint256).max, "usdc->euler allowance"
        );

        assertEq(weth.allowance(address(vault), address(vault.aavePool())), type(uint256).max, "weth->aave allowance");
        assertEq(
            weth.allowance(address(vault), address(vault.eulerProtocol())), type(uint256).max, "weth->euler allowance"
        );

        assertEq(
            weth.allowance(address(vault), address(vault.swapRouter())), type(uint256).max, "weth->swapRouter allowance"
        );
        assertEq(weth.allowance(address(vault), address(vault.scWETH())), type(uint256).max, "weth->scWETH allowance");
    }

    /// #rebalance ///

    function test_rebalance_oneProtocol() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: initialBalance,
            leverageUp: true,
            wethAmount: initialDebt
        });

        vault.rebalance(params);

        assertEq(vault.totalDebt(), initialDebt, "totalDebt");
        assertEq(vault.totalCollateral(), initialBalance, "totalCollateral");
    }

    function test_rebalance_oneProtocolSecondInOrder() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(vault), initialBalance);

        UsdcWethLendingManager.Protocol second = UsdcWethLendingManager.Protocol.EULER;
        assertTrue(UsdcWethLendingManager.Protocol.AAVE_V3 < second, "protocol order");

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = scUSDCv2.RebalanceParams({
            protocolId: second,
            supplyAmount: initialBalance,
            leverageUp: true,
            wethAmount: initialDebt
        });

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "totalCollateral");
        assertApproxEqAbs(vault.totalDebt(), initialDebt, 1, "totalDebt");

        assertEq(vault.getCollateralOnAave(), 0, "collateralOnAave");
        assertEq(vault.getDebtOnAave(), 0, "debtOnAave");

        assertApproxEqAbs(vault.getCollateralOnEuler(), initialBalance, 1, "collateralOnEuler");
        assertApproxEqAbs(vault.getDebtOnEuler(), initialDebt, 1, "debtOnEuler");
    }

    function test_rebalance_oneProtocolWithAdditionalDeposits() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: initialBalance,
            leverageUp: true,
            wethAmount: initialDebt
        });

        vault.rebalance(params);

        assertEq(vault.totalDebt(), initialDebt, "totalDebt before");
        assertEq(vault.totalCollateral(), initialBalance, "totalCollateral before");

        uint256 additionalBalance = 100_000e6;
        uint256 additionalDebt = 10 ether;
        deal(address(usdc), address(vault), additionalBalance);
        params = new scUSDCv2.RebalanceParams[](1);
        params[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: additionalBalance,
            leverageUp: true,
            wethAmount: additionalDebt
        });

        vault.rebalance(params);

        assertEq(vault.totalCollateral(), initialBalance + additionalBalance, "totalCollateral after");
        assertEq(vault.totalDebt(), initialDebt + additionalDebt, "totalDebt after");
    }

    function test_rebalance_twoProtocols() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 debtOnAave = 200 ether;
        uint256 debtOnEuler = 239.125 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: debtOnAave
        });
        params[1] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: debtOnEuler
        });

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "totalCollateral");
        assertApproxEqAbs(vault.totalDebt(), debtOnAave + debtOnEuler, 1, "totalDebt");

        assertApproxEqAbs(vault.getCollateralOnAave(), initialBalance / 2, 1, "collateralOnAave");
        assertApproxEqAbs(vault.getCollateralOnEuler(), initialBalance / 2, 1, "collateralOnEuler");

        assertApproxEqAbs(vault.getDebtOnAave(), debtOnAave, 1, "debtOnAave");
        assertApproxEqAbs(vault.getDebtOnEuler(), debtOnEuler, 1, "debtOnEuler");
    }

    function test_rebalance_twoProtocolsWithAdditionalDeposits() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 debtOnAave = 60 ether;
        uint256 debtOnEuler = 40 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: debtOnAave
        });
        params[1] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: debtOnEuler
        });

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "totalCollateral before");
        assertApproxEqAbs(vault.totalDebt(), debtOnAave + debtOnEuler, 1, "totalDebt before");

        uint256 additionalCollateralOnAave = 50_000e6;
        uint256 additionalCollateralOnEuler = 100_000e6;
        uint256 additionalDebtOnAave = 25 ether;
        uint256 additionalDebtOnEuler = 50 ether;
        deal(address(usdc), address(vault), additionalCollateralOnAave + additionalCollateralOnEuler);
        params = new scUSDCv2.RebalanceParams[](2);
        params[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: additionalCollateralOnAave,
            leverageUp: true,
            wethAmount: additionalDebtOnAave
        });
        params[1] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            supplyAmount: additionalCollateralOnEuler,
            leverageUp: true,
            wethAmount: additionalDebtOnEuler
        });

        vault.rebalance(params);

        assertApproxEqAbs(
            vault.totalCollateral(),
            initialBalance + additionalCollateralOnAave + additionalCollateralOnEuler,
            1,
            "totalCollateral after"
        );
        assertApproxEqAbs(
            vault.totalDebt(),
            debtOnAave + debtOnEuler + additionalDebtOnAave + additionalDebtOnEuler,
            1,
            "totalDebt after"
        );

        assertApproxEqAbs(
            vault.getCollateralOnAave(), initialBalance / 2 + additionalCollateralOnAave, 1, "collateralOnAave after"
        );
        assertApproxEqAbs(
            vault.getCollateralOnEuler(), initialBalance / 2 + additionalCollateralOnEuler, 1, "collateralOnEuler after"
        );

        assertApproxEqAbs(vault.getDebtOnAave(), debtOnAave + additionalDebtOnAave, 1, "debtOnAave after");
        assertApproxEqAbs(vault.getDebtOnEuler(), debtOnEuler + additionalDebtOnEuler, 1, "debtOnEuler after");
    }

    function test_rebalance_emitsEventForEachProtocol() public {
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: 50 ether
        });
        params[1] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: 50 ether
        });

        vm.expectEmit(true, true, true, true);
        emit Rebalanced(params[0].protocolId, params[0].supplyAmount, params[0].leverageUp, params[0].wethAmount);
        emit Rebalanced(params[1].protocolId, params[1].supplyAmount, params[1].leverageUp, params[1].wethAmount);

        vault.rebalance(params);
    }

    function test_rebalance_failsWhenBorrowingOverMaxLtv() public {
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), address(vault), initialBalance);
        uint256 maxLtv = vault.getMaxLtvOnEuler();
        uint256 tooLargeBorrowAmount = vault.getWethFromUsdc(initialBalance).mulWadUp(maxLtv + 0.01e18);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: tooLargeBorrowAmount
        });

        vm.expectRevert(
            abi.encodeWithSelector(scUSDCv2.LtvAboveMaxAllowed.selector, UsdcWethLendingManager.Protocol.EULER)
        );
        vault.rebalance(params);
    }

    function test_rebalance_enforcesFloatAmountToRemainInVault() public {
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), address(vault), initialBalance);
        uint256 floatPercentage = 0.02e18; // 2%
        vault.setFloatPercentage(floatPercentage);
        assertEq(vault.floatPercentage(), floatPercentage, "floatPercentage");
        uint256 expectedFloat = initialBalance.mulWadUp(floatPercentage);
        uint256 actualFloat = 1_000e6;

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: initialBalance - actualFloat,
            leverageUp: true,
            wethAmount: 50 ether
        });

        vm.expectRevert(abi.encodeWithSelector(scUSDCv2.FloatBalanceTooSmall.selector, actualFloat, expectedFloat));
        vault.rebalance(params);
    }

    /// #reallocateCapital ///

    function test_reallocateCapital_moveEverythingFromOneProtocolToAnother() public {
        uint256 totalCollateral = 1_000_000e6;
        uint256 totalDebt = 100 ether;
        deal(address(usdc), address(vault), totalCollateral);

        scUSDCv2.RebalanceParams[] memory rebalanceParams = new scUSDCv2.RebalanceParams[](1);
        rebalanceParams[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: totalCollateral,
            leverageUp: true,
            wethAmount: 100 ether
        });

        vault.rebalance(rebalanceParams);

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "totalCollateral before");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "totalDebt before");

        assertApproxEqAbs(vault.getCollateralOnAave(), totalCollateral, 1, "collateralOnAave before");
        assertApproxEqAbs(vault.getCollateralOnEuler(), 0, 1, "collateralOnEuler before");

        assertApproxEqAbs(vault.getDebtOnAave(), totalDebt, 1, "debtOnAave before");
        assertApproxEqAbs(vault.getDebtOnEuler(), 0, 1, "debtOnEuler before");

        // move everything from Aave to Euler
        uint256 collateralToMove = vault.getCollateralOnAave();
        uint256 debtToMove = vault.getDebtOnAave();
        scUSDCv2.ReallocationParams[] memory reallocateParams = new scUSDCv2.ReallocationParams[](2);
        reallocateParams[0] = scUSDCv2.ReallocationParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            isDownsize: true,
            collateralAmount: collateralToMove,
            debtAmount: debtToMove
        });
        reallocateParams[1] = scUSDCv2.ReallocationParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            isDownsize: false,
            collateralAmount: collateralToMove,
            debtAmount: debtToMove
        });

        assertFalse(vault.flashLoanInitiated(), "flashLoanInitiated");

        uint256 flashLoanAmount = debtToMove;
        vault.reallocateCapital(reallocateParams, flashLoanAmount);

        assertFalse(vault.flashLoanInitiated(), "flashLoanInitiated");

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "totalCollateral after");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "totalDebt after");

        assertApproxEqAbs(vault.getCollateralOnAave(), 0, 1, "collateralOnAave after");
        assertApproxEqAbs(vault.getCollateralOnEuler(), totalCollateral, 1, "collateralOnEuler after");

        assertApproxEqAbs(vault.getDebtOnAave(), 0, 1, "debtOnAave after");
        assertApproxEqAbs(vault.getDebtOnEuler(), totalDebt, 1, "debtOnEuler after");
    }

    function test_reallocateCapital_moveHalfFromOneProtocolToAnother() public {
        uint256 totalCollateral = 1_000_000e6;
        uint256 totalDebt = 100 ether;
        deal(address(usdc), address(vault), totalCollateral);

        scUSDCv2.RebalanceParams[] memory rebalanceParams = new scUSDCv2.RebalanceParams[](2);
        rebalanceParams[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: totalCollateral / 2,
            leverageUp: true,
            wethAmount: totalDebt / 2
        });
        rebalanceParams[1] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            supplyAmount: totalCollateral / 2,
            leverageUp: true,
            wethAmount: totalDebt / 2
        });

        vault.rebalance(rebalanceParams);

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "totalCollateral before");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "totalDebt before");

        assertApproxEqAbs(vault.getCollateralOnAave(), totalCollateral / 2, 1, "collateralOnAave before");
        assertApproxEqAbs(vault.getCollateralOnEuler(), totalCollateral / 2, 1, "collateralOnEuler before");

        assertApproxEqAbs(vault.getDebtOnAave(), totalDebt / 2, 1, "debtOnAave before");
        assertApproxEqAbs(vault.getDebtOnEuler(), totalDebt / 2, 1, "debtOnEuler before");

        // move half of the position from Aave to Euler
        uint256 collateralToMove = vault.getCollateralOnAave() / 2;
        uint256 debtToMove = vault.getDebtOnAave() / 2;

        scUSDCv2.ReallocationParams[] memory reallocateParams = new scUSDCv2.ReallocationParams[](2);
        reallocateParams[0] = scUSDCv2.ReallocationParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            isDownsize: true,
            collateralAmount: collateralToMove,
            debtAmount: debtToMove
        });
        reallocateParams[1] = scUSDCv2.ReallocationParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            isDownsize: false,
            collateralAmount: collateralToMove,
            debtAmount: debtToMove
        });

        uint256 flashLoanAmount = 100 ether;
        vault.reallocateCapital(reallocateParams, flashLoanAmount);

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "totalCollateral after");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "totalDebt after");

        assertApproxEqAbs(vault.getCollateralOnAave(), totalCollateral / 4, 1, "collateralOnAave after");
        assertApproxEqAbs(vault.getCollateralOnEuler(), totalCollateral * 3 / 4, 1, "collateralOnEuler after");

        assertApproxEqAbs(vault.getDebtOnAave(), totalDebt / 4, 1, "debtOnAave after");
        assertApproxEqAbs(vault.getDebtOnEuler(), totalDebt * 3 / 4, 1, "debtOnEuler after");
    }

    function test_reallocateCapital_EmitsEventForEveryAffectedProtocol() public {
        uint256 totalCollateral = 1_000_000e6;
        uint256 totalDebt = 100 ether;
        deal(address(usdc), address(vault), totalCollateral);

        scUSDCv2.RebalanceParams[] memory rebalanceParams = new scUSDCv2.RebalanceParams[](1);
        rebalanceParams[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: totalCollateral,
            leverageUp: true,
            wethAmount: totalDebt
        });

        vault.rebalance(rebalanceParams);

        // move half from Aave to Euler
        uint256 collateralToMove = vault.getCollateralOnAave() / 2;
        uint256 debtToMove = vault.getDebtOnAave() / 2;
        scUSDCv2.ReallocationParams[] memory reallocateParams = new scUSDCv2.ReallocationParams[](2);
        reallocateParams[0] = scUSDCv2.ReallocationParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            isDownsize: true,
            collateralAmount: collateralToMove,
            debtAmount: debtToMove
        });
        reallocateParams[1] = scUSDCv2.ReallocationParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            isDownsize: false,
            collateralAmount: collateralToMove,
            debtAmount: debtToMove
        });

        uint256 flashLoanAmount = debtToMove;
        vm.expectEmit(true, true, true, true);
        emit Reallocated(UsdcWethLendingManager.Protocol.AAVE_V3, true, collateralToMove, debtToMove);
        emit Reallocated(UsdcWethLendingManager.Protocol.EULER, false, collateralToMove, debtToMove);

        vault.reallocateCapital(reallocateParams, flashLoanAmount);
    }

    function test_reallocateCapital_worksWhenCalledMultipleTimes() public {
        uint256 totalCollateral = 1_000_000e6;
        uint256 totalDebt = 100 ether;
        deal(address(usdc), address(vault), totalCollateral);

        scUSDCv2.RebalanceParams[] memory rebalanceParams = new scUSDCv2.RebalanceParams[](2);
        rebalanceParams[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: totalCollateral / 2,
            leverageUp: true,
            wethAmount: totalDebt / 2
        });
        rebalanceParams[1] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            supplyAmount: totalCollateral / 2,
            leverageUp: true,
            wethAmount: totalDebt / 2
        });

        vault.rebalance(rebalanceParams);

        // 1. move half of the position from Aave to Euler
        uint256 collateralToMove = vault.getCollateralOnAave() / 2;
        uint256 debtToMove = vault.getDebtOnAave() / 2;

        scUSDCv2.ReallocationParams[] memory reallocateParams = new scUSDCv2.ReallocationParams[](2);
        reallocateParams[0] = scUSDCv2.ReallocationParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            isDownsize: true,
            collateralAmount: collateralToMove,
            debtAmount: debtToMove
        });
        reallocateParams[1] = scUSDCv2.ReallocationParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            isDownsize: false,
            collateralAmount: collateralToMove,
            debtAmount: debtToMove
        });

        uint256 flashLoanAmount = debtToMove;
        vault.reallocateCapital(reallocateParams, flashLoanAmount);

        // 2. move everyting to Aave
        collateralToMove = vault.getCollateralOnEuler();
        debtToMove = vault.getDebtOnEuler();

        reallocateParams = new scUSDCv2.ReallocationParams[](2);
        reallocateParams[0] = scUSDCv2.ReallocationParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            isDownsize: true,
            collateralAmount: collateralToMove,
            debtAmount: debtToMove
        });
        reallocateParams[1] = scUSDCv2.ReallocationParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            isDownsize: false,
            collateralAmount: collateralToMove,
            debtAmount: debtToMove
        });

        flashLoanAmount = debtToMove;
        vault.reallocateCapital(reallocateParams, flashLoanAmount);

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "totalCollateral");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "totalDebt");

        assertApproxEqAbs(vault.getCollateralOnAave(), totalCollateral, 1, "collateralOnAave");
        assertApproxEqAbs(vault.getCollateralOnEuler(), 0, 1, "collateralOnEuler");

        assertApproxEqAbs(vault.getDebtOnAave(), totalDebt, 1, "debtOnAave");
        assertApproxEqAbs(vault.getDebtOnEuler(), 0, 1, "debtOnEuler");
    }

    // #receiveFlashLoan ///

    function test_receiveFlashLoan_FailsIfCallerIsNotBalancerVault() public {
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory feeAmounts = new uint256[](1);

        vm.expectRevert(InvalidFlashLoanCaller.selector);
        vault.receiveFlashLoan(tokens, amounts, feeAmounts, "");
    }

    function test_receiveFlashLoan_FailsIfInitiatorIsNotVault() public {
        IVault balancer = vault.balancerVault();
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        tokens[0] = address(weth);
        amounts[0] = 100e18;

        vm.expectRevert(InvalidFlashLoanCaller.selector);
        balancer.flashLoan(address(vault), tokens, amounts, abi.encode(0, 0));
    }

    // #sellProfit //

    function test_sellProfit_FailsIfCallerIsNotKeeper() public {
        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.sellProfit(0);
    }

    function test_sellProfit_FailsIfProfitsAre0() public {
        vm.prank(keeper);
        vm.expectRevert(NoProfitsToSell.selector);
        vault.sellProfit(0);
    }

    function test_sellProfit_onlySellsProfit() public {
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: 50 ether
        });
        params[1] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: 50 ether
        });

        vm.prank(keeper);
        vault.rebalance(params);

        // add 100% profit to the weth vault
        uint256 initialWethInvested = vault.wethInvested();
        deal(address(weth), address(wethVault), initialWethInvested * 2);

        uint256 usdcBalanceBefore = vault.usdcBalance();
        uint256 profit = vault.getProfit();

        vm.prank(keeper);
        vault.sellProfit(0);

        uint256 expectedUsdcBalance = usdcBalanceBefore + vault.getUsdcFromWeth(profit);
        assertApproxEqRel(vault.usdcBalance(), expectedUsdcBalance, 0.01e18, "usdc balance");
        assertApproxEqRel(vault.wethInvested(), initialWethInvested, 0.001e18, "sold more than actual profit");
    }

    function test_sellProfit_emitsEvent() public {
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: 50 ether
        });
        params[1] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: 50 ether
        });

        vm.prank(keeper);
        vault.rebalance(params);

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested * 2);
        uint256 profit = vault.wethInvested() - vault.totalDebt();

        vm.expectEmit(true, true, true, true);
        emit ProfitSold(profit, 171256_066845);
        vm.prank(keeper);
        vault.sellProfit(0);
    }

    function test_sellProfit_FailsIfAmountReceivedIsLeessThanAmountOutMin() public {
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: 50 ether
        });
        params[1] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: 50 ether
        });

        vm.prank(keeper);
        vault.rebalance(params);

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested * 2);

        uint256 tooLargeUsdcAmountOutMin = vault.getUsdcFromWeth(vault.getProfit()).mulWadDown(1.05e18); // add 5% more than expected

        vm.prank(keeper);
        vm.expectRevert("Too little received");
        vault.sellProfit(tooLargeUsdcAmountOutMin);
    }

    /// #withdraw ///

    // TODO: test with 1 protocol
    // TODO: test with 2 protocols

    // TODO: either pull from all or from the one with lowest allocation? a field with protocols to withdraw from

    function test_withdraw_pullsFundsFromAllProtocols() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), alice, initialBalance);

        vm.startPrank(alice);
        usdc.approve(address(vault), initialBalance);
        vault.deposit(initialBalance, alice);
        vm.stopPrank();

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: initialDebt / 2
        });
        params[1] = scUSDCv2.RebalanceParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            supplyAmount: initialBalance / 2,
            leverageUp: true,
            wethAmount: initialDebt / 2
        });

        vault.rebalance(params);

        uint256 withdrawAmount = initialBalance / 2;
        uint256 endCollateral = initialBalance / 2;
        uint256 endDebt = initialDebt / 2;
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertApproxEqRel(usdc.balanceOf(alice), withdrawAmount, 0.01e18, "alice usdc balance");

        assertApproxEqRel(vault.totalCollateral(), endCollateral, 0.01e18, "totalCollateral");
        assertApproxEqRel(vault.totalDebt(), endDebt, 0.01e18, "total Debt");

        assertApproxEqRel(vault.getCollateralOnAave(), endCollateral / 2, 0.01e18, "collateral on aave");
        assertApproxEqRel(vault.getCollateralOnEuler(), endCollateral / 2, 0.01e18, "collateral on euler");
        assertApproxEqRel(vault.getDebtOnAave(), endDebt / 2, 0.01e18, "debt on aave");
        assertApproxEqRel(vault.getDebtOnEuler(), endDebt / 2, 0.01e18, "debt on euler");
    }

    /// internal helper functions ///

    function _createDefaultUsdcVaultConstructorParams(scWETH scWeth)
        internal
        view
        returns (scUSDCv2.ConstructorParams memory)
    {
        return scUSDCv2.ConstructorParams({
            admin: address(this),
            keeper: keeper,
            scWETH: scWeth,
            usdc: ERC20(C.USDC),
            weth: WETH(payable(C.WETH)),
            aavePool: IPool(C.AAVE_POOL),
            aavePoolDataProvider: IPoolDataProvider(C.AAVE_POOL_DATA_PROVIDER),
            aaveAUsdc: IAToken(C.AAVE_AUSDC_TOKEN),
            aaveVarDWeth: ERC20(C.AAVAAVE_VAR_DEBT_WETH_TOKEN),
            uniswapSwapRouter: ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER),
            chainlinkUsdcToEthPriceFeed: AggregatorV3Interface(C.CHAINLINK_USDC_ETH_PRICE_FEED),
            balancerVault: IVault(C.BALANCER_VAULT),
            eulerProtocol: C.EULER_PROTOCOL,
            eulerMarkets: IEulerMarkets(C.EULER_MARKETS),
            eulerEUsdc: IEulerEToken(C.EULER_EUSDC_TOKEN),
            eulerDWeth: IEulerDToken(C.EULER_DWETH_TOKEN),
            eulerRewardsToken: ERC20(C.EULER_REWARDS_TOKEN)
        });
    }
}
