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
        // assign keeper role to deployer
        vault.grantRole(vault.KEEPER_ROLE(), address(this));
    }

    /// #constructor ///

    function test_constructor() public {
        assertEq(address(vault.asset()), address(usdc));
        assertEq(address(vault.scWETH()), address(wethVault));

        // check approvals
        assertEq(
            usdc.allowance(address(vault), address(vault.aaveV3Pool())), type(uint256).max, "usdc->aave v3 allowance"
        );
        assertEq(
            usdc.allowance(address(vault), address(vault.eulerProtocol())), type(uint256).max, "usdc->euler allowance"
        );
        assertEq(
            usdc.allowance(address(vault), address(vault.aaveV2Pool())), type(uint256).max, "usdc->aave v2 allowance"
        );

        assertEq(
            weth.allowance(address(vault), address(vault.aaveV3Pool())), type(uint256).max, "weth->aave v3 allowance"
        );
        assertEq(
            weth.allowance(address(vault), address(vault.eulerProtocol())), type(uint256).max, "weth->euler allowance"
        );
        assertEq(
            weth.allowance(address(vault), address(vault.aaveV2Pool())), type(uint256).max, "weth->aave v2 allowance"
        );

        assertEq(
            weth.allowance(address(vault), address(vault.swapRouter())), type(uint256).max, "weth->swapRouter allowance"
        );
        assertEq(weth.allowance(address(vault), address(vault.scWETH())), type(uint256).max, "weth->scWETH allowance");
    }

    /// #rebalance ///

    function test_rebalance_FailsIfCallerIsNotKeeper() public {
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance, true, 0);

        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.rebalance(params);
    }

    function test_rebalance_BorrowOnlyOnAaveV3() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance, true, initialDebt);

        vault.rebalance(params);

        assertEq(vault.totalDebt(), initialDebt, "total debt");
        assertEq(vault.totalCollateral(), initialBalance, "total collateral");
    }

    function test_rebalance_BorrowOnlyOnEuler() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, initialBalance, true, initialDebt);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), initialDebt, 1, "total debt");

        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V3, 0, 0);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.EULER, initialBalance, initialDebt);
    }

    function test_rebalance_BorrowOnlyOnAaveV2() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, true, initialDebt);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), initialDebt, 1, "total debt");

        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, initialDebt);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V3, 0, 0);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.EULER, 0, 0);
    }

    function test_rebalance_OneProtocolLeverageDown() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, true, initialDebt);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), initialDebt, 1, "total debt");

        // leverage down
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V2, 0, false, initialDebt / 2);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), initialDebt / 2, 1, "total debt");

        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, initialDebt / 2);
    }

    function test_rebalance_OneProtocolLeverageUp() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, true, initialDebt);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), initialDebt, 1, "total debt");

        // leverage down
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V2, 0, true, initialDebt / 2);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), initialDebt * 3 / 2, 1, "total debt");

        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, initialDebt * 3 / 2);
    }

    function test_rebalance_OneProtocolWithAdditionalDeposits() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance, true, initialDebt);

        vault.rebalance(params);

        assertEq(vault.totalDebt(), initialDebt, "total debt before");
        assertEq(vault.totalCollateral(), initialBalance, "total collateral before");

        uint256 additionalBalance = 100_000e6;
        uint256 additionalDebt = 10 ether;
        deal(address(usdc), address(vault), additionalBalance);
        params = new scUSDCv2.RebalanceParams[](1);
        params[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, additionalBalance, true, additionalDebt);

        vault.rebalance(params);

        assertEq(vault.totalCollateral(), initialBalance + additionalBalance, "total collateral after");
        assertEq(vault.totalDebt(), initialDebt + additionalDebt, "total debt after");
    }

    function test_rebalance_TwoProtocols() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 debtOnAaveV3 = 200 ether;
        uint256 debtOnEuler = 239.125 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 2, true, debtOnAaveV3);
        params[1] = _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, initialBalance / 2, true, debtOnEuler);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), debtOnAaveV3 + debtOnEuler, 1, "total debt");

        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 2, debtOnAaveV3);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.EULER, initialBalance / 2, debtOnEuler);
    }

    function test_rebalance_TwoProtocolsWithAdditionalDeposits() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 debtOnAaveV3 = 60 ether;
        uint256 debtOnEuler = 40 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 2, true, debtOnAaveV3);
        params[1] = _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, initialBalance / 2, true, debtOnEuler);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral before");
        assertApproxEqAbs(vault.totalDebt(), debtOnAaveV3 + debtOnEuler, 1, "total debt before");

        uint256 additionalCollateralOnAaveV3 = 50_000e6;
        uint256 additionalCollateralOnEuler = 100_000e6;
        uint256 additionalDebtOnAaveV3 = 25 ether;
        uint256 additionalDebtOnEuler = 50 ether;
        deal(address(usdc), address(vault), additionalCollateralOnAaveV3 + additionalCollateralOnEuler);

        params = new scUSDCv2.RebalanceParams[](2);
        params[0] = _createRebalanceParams(
            UsdcWethLendingManager.Protocol.AAVE_V3, additionalCollateralOnAaveV3, true, additionalDebtOnAaveV3
        );
        params[1] = _createRebalanceParams(
            UsdcWethLendingManager.Protocol.EULER, additionalCollateralOnEuler, true, additionalDebtOnEuler
        );

        vault.rebalance(params);

        assertApproxEqAbs(
            vault.totalCollateral(),
            initialBalance + additionalCollateralOnAaveV3 + additionalCollateralOnEuler,
            1,
            "total collateral after"
        );
        assertApproxEqAbs(
            vault.totalDebt(),
            debtOnAaveV3 + debtOnEuler + additionalDebtOnAaveV3 + additionalDebtOnEuler,
            1,
            "total debt after"
        );

        _assertLendingPosition(
            UsdcWethLendingManager.Protocol.AAVE_V3,
            initialBalance / 2 + additionalCollateralOnAaveV3,
            debtOnAaveV3 + additionalDebtOnAaveV3
        );
        _assertLendingPosition(
            UsdcWethLendingManager.Protocol.EULER,
            initialBalance / 2 + additionalCollateralOnEuler,
            debtOnEuler + additionalDebtOnEuler
        );
    }

    function test_rebalance_TwoProtocolsLeveragingUpAndDown() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 debtOnAaveV3 = 160 ether;
        uint256 debtOnEuler = 100 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 2, true, debtOnAaveV3);
        params[1] = _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, initialBalance / 2, true, debtOnEuler);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral before");
        assertApproxEqAbs(vault.totalDebt(), debtOnAaveV3 + debtOnEuler, 1, "total debt before");

        uint256 additionalCollateralOnAaveV3 = 50_000e6;
        uint256 additionalCollateralOnEuler = 0;
        uint256 additionalDebtOnAaveV3 = 40 ether; // leverage up
        uint256 debtReductionOnEuler = 80 ether; // leverage down
        deal(address(usdc), address(vault), additionalCollateralOnAaveV3 + additionalCollateralOnEuler);

        params = new scUSDCv2.RebalanceParams[](2);
        params[0] = _createRebalanceParams(
            UsdcWethLendingManager.Protocol.AAVE_V3, additionalCollateralOnAaveV3, true, additionalDebtOnAaveV3
        );
        params[1] = _createRebalanceParams(
            UsdcWethLendingManager.Protocol.EULER, additionalCollateralOnEuler, false, debtReductionOnEuler
        );

        vault.rebalance(params);

        assertApproxEqAbs(
            vault.totalCollateral(),
            initialBalance + additionalCollateralOnAaveV3 + additionalCollateralOnEuler,
            1,
            "total collateral after"
        );
        assertApproxEqAbs(
            vault.totalDebt(),
            debtOnAaveV3 + debtOnEuler + additionalDebtOnAaveV3 - debtReductionOnEuler,
            1,
            "total debt after"
        );

        _assertLendingPosition(
            UsdcWethLendingManager.Protocol.AAVE_V3,
            initialBalance / 2 + additionalCollateralOnAaveV3,
            debtOnAaveV3 + additionalDebtOnAaveV3
        );
        _assertLendingPosition(
            UsdcWethLendingManager.Protocol.EULER,
            initialBalance / 2 + additionalCollateralOnEuler,
            debtOnEuler - debtReductionOnEuler
        );
    }

    function test_rebalance_ThreeProtocols() public {
        uint256 initialBalance = 1_200_000e6;
        uint256 debtOnAaveV3 = 140 ether;
        uint256 debtOnEuler = 150 ether;
        uint256 debtOnAaveV2 = 160 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](3);
        params[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 3, true, debtOnAaveV3);
        params[1] = _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, initialBalance / 3, true, debtOnEuler);
        params[2] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance / 3, true, debtOnAaveV2);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), debtOnAaveV3 + debtOnEuler + debtOnAaveV2, 1, "total debt");

        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 3, debtOnAaveV3);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance / 3, debtOnAaveV2);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.EULER, initialBalance / 3, debtOnEuler);
    }

    function test_rebalance_ThreeProtocolsLeveragingDown() public {
        uint256 initialBalance = 1_200_000e6;
        uint256 debtOnAaveV3 = 140 ether;
        uint256 debtOnEuler = 150 ether;
        uint256 debtOnAaveV2 = 160 ether;
        uint256 totalDebt = debtOnAaveV3 + debtOnAaveV2 + debtOnEuler;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](3);
        params[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 3, true, debtOnAaveV3);
        params[1] = _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, initialBalance / 3, true, debtOnEuler);
        params[2] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance / 3, true, debtOnAaveV2);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "total debt");

        uint256 debtReductionOnAaveV3 = 40;
        uint256 debtReductionOnEuler = 50;
        uint256 debtReductionOnAaveV2 = 60;
        uint256 totalDebtReduction = debtReductionOnAaveV3 + debtReductionOnEuler + debtReductionOnAaveV2;
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, 0, false, debtReductionOnAaveV3);
        params[1] = _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, 0, false, debtReductionOnEuler);
        params[2] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V2, 0, false, debtReductionOnAaveV2);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), totalDebt - totalDebtReduction, 1, "total debt");

        _assertLendingPosition(
            UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 3, debtOnAaveV3 - debtReductionOnAaveV3
        );
        _assertLendingPosition(
            UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance / 3, debtOnAaveV2 - debtReductionOnAaveV2
        );
        _assertLendingPosition(
            UsdcWethLendingManager.Protocol.EULER, initialBalance / 3, debtOnEuler - debtReductionOnEuler
        );
    }

    function test_rebalance_EmitsEventForEachProtocol() public {
        uint256 initialBalance = 1_500_000e6;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](3);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 3, true, 150 ether);
        params[1] = _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, initialBalance / 6, true, 50 ether);
        params[2] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance / 2, true, 250 ether);

        vm.expectEmit(true, true, true, true);
        emit Rebalanced(params[0].protocolId, params[0].supplyAmount, params[0].leverageUp, params[0].wethAmount);
        emit Rebalanced(params[1].protocolId, params[1].supplyAmount, params[1].leverageUp, params[1].wethAmount);
        emit Rebalanced(params[2].protocolId, params[2].supplyAmount, params[2].leverageUp, params[2].wethAmount);

        vault.rebalance(params);
    }

    function test_rebalance_FailsWhenBorrowingOverMaxLtv() public {
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), address(vault), initialBalance);
        uint256 maxLtv = vault.getMaxLtv(UsdcWethLendingManager.Protocol.EULER);
        uint256 tooLargeBorrowAmount = vault.getWethFromUsdc(initialBalance).mulWadUp(maxLtv + 0.01e18);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(
            UsdcWethLendingManager.Protocol.EULER, initialBalance / 2, true, tooLargeBorrowAmount
        );

        vm.expectRevert(
            abi.encodeWithSelector(scUSDCv2.LtvAboveMaxAllowed.selector, UsdcWethLendingManager.Protocol.EULER)
        );
        vault.rebalance(params);
    }

    function test_rebalance_EnforcesFloatAmountToRemainInVault() public {
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), address(vault), initialBalance);
        uint256 floatPercentage = 0.02e18; // 2%
        vault.setFloatPercentage(floatPercentage);
        assertEq(vault.floatPercentage(), floatPercentage, "floatPercentage");
        uint256 expectedFloat = initialBalance.mulWadUp(floatPercentage);
        uint256 actualFloat = 1_000e6;

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(
            UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance - actualFloat, true, 50 ether
        );

        vm.expectRevert(abi.encodeWithSelector(scUSDCv2.FloatBalanceTooSmall.selector, actualFloat, expectedFloat));
        vault.rebalance(params);
    }

    /// #reallocateCapital ///

    function test_reallocateCapital_FailsIfCallerIsNotKeeper() public {
        scUSDCv2.ReallocationParams[] memory reallocateParams = new scUSDCv2.ReallocationParams[](1);

        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.reallocateCapital(reallocateParams, 0);
    }

    function test_reallocateCapital_FailsIfFlashLoanParameterIsZero() public {
        scUSDCv2.ReallocationParams[] memory reallocateParams = new scUSDCv2.ReallocationParams[](1);

        vm.expectRevert(FlashLoanAmountZero.selector);
        vault.reallocateCapital(reallocateParams, 0);
    }

    function test_reallocateCapital_MoveEverythingFromOneProtocolToAnother() public {
        uint256 totalCollateral = 1_000_000e6;
        uint256 totalDebt = 100 ether;
        deal(address(usdc), address(vault), totalCollateral);

        scUSDCv2.RebalanceParams[] memory rebalanceParams = new scUSDCv2.RebalanceParams[](1);
        rebalanceParams[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral, true, 100 ether);

        vault.rebalance(rebalanceParams);

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "total collateral before");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "total debt before");

        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral, totalDebt);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V2, 0, 0);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.EULER, 0, 0);

        // move everything from Aave to Euler
        uint256 collateralToMove = totalCollateral;
        uint256 debtToMove = totalDebt;
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

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        uint256 flashLoanAmount = debtToMove;
        vault.reallocateCapital(reallocateParams, flashLoanAmount);

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "total collateral after");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "total debt after");

        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V3, 0, 0);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V2, 0, 0);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.EULER, totalCollateral, totalDebt);
    }

    function test_reallocateCapital_MoveHalfFromOneProtocolToAnother() public {
        uint256 totalCollateral = 1_000_000e6;
        uint256 totalDebt = 100 ether;
        deal(address(usdc), address(vault), totalCollateral);

        scUSDCv2.RebalanceParams[] memory rebalanceParams = new scUSDCv2.RebalanceParams[](2);
        rebalanceParams[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral / 2, true, totalDebt / 2);
        rebalanceParams[1] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, totalCollateral / 2, true, totalDebt / 2);

        vault.rebalance(rebalanceParams);

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "total collateral before");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "total debt before");

        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral / 2, totalDebt / 2);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V2, 0, 0);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.EULER, totalCollateral / 2, totalDebt / 2);

        // move half of the position from Aave to Euler
        uint256 collateralToMove = totalCollateral / 4;
        uint256 debtToMove = totalDebt / 4;

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

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "total collateral after");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "total debt after");

        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral / 4, totalDebt / 4);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V2, 0, 0);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.EULER, totalCollateral * 3 / 4, totalDebt * 3 / 4);
    }

    function test_reallocateCapital_EmitsEventForEveryAffectedProtocol() public {
        uint256 totalCollateral = 1_000_000e6;
        uint256 totalDebt = 100 ether;
        deal(address(usdc), address(vault), totalCollateral);

        scUSDCv2.RebalanceParams[] memory rebalanceParams = new scUSDCv2.RebalanceParams[](1);
        rebalanceParams[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral, true, totalDebt);

        vault.rebalance(rebalanceParams);

        // move half from Aave to Euler
        uint256 collateralToMove = totalCollateral / 2;
        uint256 debtToMove = totalDebt / 2;
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

    function test_reallocateCapital_WorksWhenCalledMultipleTimes() public {
        uint256 totalCollateral = 1_000_000e6;
        uint256 totalDebt = 100 ether;
        deal(address(usdc), address(vault), totalCollateral);

        scUSDCv2.RebalanceParams[] memory rebalanceParams = new scUSDCv2.RebalanceParams[](2);
        rebalanceParams[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral / 2, true, totalDebt / 2);
        rebalanceParams[1] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, totalCollateral / 2, true, totalDebt / 2);

        vault.rebalance(rebalanceParams);

        // 1. move half of the position from Aave to Euler
        uint256 collateralToMove = totalCollateral / 2;
        uint256 debtToMove = totalDebt / 2;

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
        (collateralToMove, debtToMove) = _getCollateralAndDebt(UsdcWethLendingManager.Protocol.EULER);

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

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "total debt");

        _assertLendingPosition(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral, totalDebt);
        _assertLendingPosition(UsdcWethLendingManager.Protocol.EULER, 0, 0);
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

    function test_sellProfit_DisinvestsAndDoesNotChageCollateralOrDebt() public {
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 2, true, 50 ether);
        params[1] = _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, initialBalance / 2, true, 50 ether);

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

    function test_sellProfit_EmitsEvent() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 2, true, initialDebt / 2);
        params[1] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, initialBalance / 2, true, initialDebt / 2);

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
        uint256 initialDebt = 200 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 2, true, initialDebt / 2);
        params[1] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, initialBalance / 2, true, initialDebt / 2);

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

    function test_withdraw_WorksWithOneProtocol() public {
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), alice, initialBalance);

        vm.startPrank(alice);
        usdc.approve(address(vault), initialBalance);
        vault.deposit(initialBalance, alice);
        vm.stopPrank();

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance, true, 200 ether);

        vault.rebalance(params);

        uint256 withdrawAmount = vault.convertToAssets(vault.balanceOf(alice));
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(usdc.balanceOf(alice), withdrawAmount, "alice usdc balance");
    }

    function test_withdraw_PullsFundsFromFloatFirst() public {
        uint256 floatPercentage = 0.1e18; // 10 %
        vault.setFloatPercentage(floatPercentage);
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), alice, initialBalance);

        vm.startPrank(alice);
        usdc.approve(address(vault), initialBalance);
        vault.deposit(initialBalance, alice);
        vm.stopPrank();

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = params[0] = _createRebalanceParams(
            UsdcWethLendingManager.Protocol.EULER, initialBalance.mulWadDown(1e18 - floatPercentage), true, 200 ether
        );

        vault.rebalance(params);

        uint256 collateralBefore = vault.totalCollateral();
        uint256 debtBefore = vault.totalDebt();

        uint256 withdrawAmount = usdc.balanceOf(address(vault));
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(usdc.balanceOf(alice), withdrawAmount, "alice usdc balance");
        assertEq(vault.totalCollateral(), collateralBefore, "collateral not expected to change");
        assertEq(vault.totalDebt(), debtBefore, "total debt not expected to change");
    }

    function test_withdraw_PullsFundsFromProtocolWhenFloatIsNotEnough() public {
        uint256 floatPercentage = 0.1e18; // 10 %
        vault.setFloatPercentage(floatPercentage);
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), alice, initialBalance);

        vm.startPrank(alice);
        usdc.approve(address(vault), initialBalance);
        vault.deposit(initialBalance, alice);
        vm.stopPrank();

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(
            UsdcWethLendingManager.Protocol.EULER, initialBalance.mulWadDown(1e18 - floatPercentage), true, 200 ether
        );

        vault.rebalance(params);

        uint256 withdrawAmount = vault.convertToAssets(vault.balanceOf(alice));
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(usdc.balanceOf(alice), withdrawAmount, "alice usdc balance");
        assertApproxEqAbs(vault.totalCollateral(), 0, 1, "collateral not 0");
        assertApproxEqAbs(vault.totalDebt(), 0, 1, "debt not 0");
    }

    function test_withdraw_PullsFundsFromAllProtocolsInEqualWeight() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), alice, initialBalance);

        vm.startPrank(alice);
        usdc.approve(address(vault), initialBalance);
        vault.deposit(initialBalance, alice);
        vm.stopPrank();

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 2, true, initialDebt / 2);
        params[1] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, initialBalance / 2, true, initialDebt / 2);

        vault.rebalance(params);

        uint256 withdrawAmount = initialBalance / 2;
        uint256 endCollateral = initialBalance / 2;
        uint256 endDebt = initialDebt / 2;
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertApproxEqRel(usdc.balanceOf(alice), withdrawAmount, 0.01e18, "alice usdc balance");

        assertApproxEqRel(vault.totalCollateral(), endCollateral, 0.01e18, "total collateral");
        assertApproxEqRel(vault.totalDebt(), endDebt, 0.01e18, "total debt");

        (uint256 collateralOnAaveV3, uint256 debtOnAaveV3) =
            _getCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3);
        (uint256 collateralOnEuler, uint256 debtOnEuler) = _getCollateralAndDebt(UsdcWethLendingManager.Protocol.EULER);

        assertApproxEqRel(collateralOnAaveV3, endCollateral / 2, 0.01e18, "collateral on aave v3");
        assertApproxEqRel(collateralOnEuler, endCollateral / 2, 0.01e18, "collateral on euler");
        assertApproxEqRel(debtOnAaveV3, endDebt / 2, 0.01e18, "debt on aave v3");
        assertApproxEqRel(debtOnEuler, endDebt / 2, 0.01e18, "debt on euler");
    }

    /// #getLendingPositionsInfo ///

    function test_getLendingPositionsInfo_ReturnsInfoOnOneProtocol() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        uint256 expectedLtv = vault.getUsdcFromWeth(initialDebt).divWadUp(initialBalance);
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance, true, initialDebt);

        vault.rebalance(params);

        UsdcWethLendingManager.Protocol[] memory protocolIds = new UsdcWethLendingManager.Protocol[](1);
        protocolIds[0] = UsdcWethLendingManager.Protocol.AAVE_V3;

        scUSDCv2.LendingPositionInfo[] memory positions = vault.getLendingPositionsInfo(protocolIds);

        assertEq(positions.length, 1, "positions info length");
        assertEq(uint8(positions[0].protocolId), uint8(UsdcWethLendingManager.Protocol.AAVE_V3), "protocolId");
        assertEq(positions[0].collateral, initialBalance, "supplyAmount");
        assertEq(positions[0].debt, initialDebt, "borrowAmount");
        assertApproxEqRel(positions[0].ltv, expectedLtv, 0.001e18, "ltv");
    }

    function test_getLendingPositionsInfo_ReturnsInfoOnMultipleProtocols() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        uint256 expectedLtv = vault.getUsdcFromWeth(initialDebt / 2).divWadUp(initialBalance / 2);
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 2, true, initialDebt / 2);
        params[1] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, initialBalance / 2, true, initialDebt / 2);

        vault.rebalance(params);

        UsdcWethLendingManager.Protocol[] memory protocolIds = new UsdcWethLendingManager.Protocol[](2);
        protocolIds[0] = UsdcWethLendingManager.Protocol.AAVE_V3;
        protocolIds[1] = UsdcWethLendingManager.Protocol.EULER;

        scUSDCv2.LendingPositionInfo[] memory positions = vault.getLendingPositionsInfo(protocolIds);

        assertEq(positions.length, 2, "positions info length");
        assertEq(
            uint8(positions[0].protocolId), uint8(UsdcWethLendingManager.Protocol.AAVE_V3), "protocolId not AAVE_V3"
        );
        assertApproxEqAbs(positions[0].collateral, initialBalance / 2, 1, "aave v3 collateral");
        assertApproxEqAbs(positions[0].debt, initialDebt / 2, 1, "aave v3 debt");
        assertApproxEqRel(positions[0].ltv, expectedLtv, 0.001e18, "aave v3 ltv");

        assertEq(uint8(positions[1].protocolId), uint8(UsdcWethLendingManager.Protocol.EULER), "protocolId not EULER");
        assertApproxEqAbs(positions[1].collateral, initialBalance / 2, 1, "euler collateral");
        assertApproxEqAbs(positions[1].debt, initialDebt / 2, 1, "euler debt");
        assertApproxEqRel(positions[1].ltv, expectedLtv, 0.001e18, "euler ltv");
    }

    function test_getLendingPositionsInfo_WorksWhenProtocolRequestedIsNotUsed() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        uint256 expectedLtv = vault.getUsdcFromWeth(initialDebt).divWadUp(initialBalance);
        deal(address(usdc), address(vault), initialBalance);

        // not using AAVE_V3
        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, initialBalance, true, initialDebt);

        vault.rebalance(params);

        UsdcWethLendingManager.Protocol[] memory protocolIds = new UsdcWethLendingManager.Protocol[](2);
        protocolIds[0] = UsdcWethLendingManager.Protocol.AAVE_V3;
        protocolIds[1] = UsdcWethLendingManager.Protocol.EULER;

        scUSDCv2.LendingPositionInfo[] memory positions = vault.getLendingPositionsInfo(protocolIds);

        assertEq(positions.length, 2, "positions info length");
        assertEq(
            uint8(positions[0].protocolId), uint8(UsdcWethLendingManager.Protocol.AAVE_V3), "protocolId not AAVE_V3"
        );
        assertEq(positions[0].collateral, 0, "aave v3 collateral not 0");
        assertEq(positions[0].debt, 0, "aave v3 debt not 0");
        assertEq(positions[0].ltv, 0, "aave v3 ltv not 0");

        assertEq(uint8(positions[1].protocolId), uint8(UsdcWethLendingManager.Protocol.EULER), "protocolId not EULER");
        assertApproxEqAbs(positions[1].collateral, initialBalance, 1, "euler collateral");
        assertApproxEqAbs(positions[1].debt, initialDebt, 1, "euler debt");
        assertApproxEqRel(positions[1].ltv, expectedLtv, 0.001e18, "euler ltv");
    }

    /// internal helper functions ///

    function _createDefaultUsdcVaultConstructorParams(scWETH scWeth)
        internal
        view
        returns (scUSDCv2.ConstructorParams memory)
    {
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
            aUsdc: ERC20(C.AAVE_V2_AUSDC_TOKEN),
            varDWeth: ERC20(C.AAVE_V2_VAR_DEBT_WETH_TOKEN)
        });

        return scUSDCv2.ConstructorParams({
            admin: address(this),
            keeper: keeper,
            scWETH: scWeth,
            usdc: ERC20(C.USDC),
            weth: WETH(payable(C.WETH)),
            aaveV3: aaveV3,
            aaveV2: aaveV2,
            euler: euler,
            uniswapSwapRouter: ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER),
            chainlinkUsdcToEthPriceFeed: AggregatorV3Interface(C.CHAINLINK_USDC_ETH_PRICE_FEED),
            balancerVault: IVault(C.BALANCER_VAULT)
        });
    }

    function _createRebalanceParams(
        UsdcWethLendingManager.Protocol _protocolId,
        uint256 _supplyAmount,
        bool _leverageUp,
        uint256 _wethAmount
    ) internal pure returns (scUSDCv2.RebalanceParams memory) {
        return scUSDCv2.RebalanceParams({
            protocolId: _protocolId,
            supplyAmount: _supplyAmount,
            leverageUp: _leverageUp,
            wethAmount: _wethAmount
        });
    }

    function _assertLendingPosition(
        UsdcWethLendingManager.Protocol _protocolId,
        uint256 _expectedCollateral,
        uint256 _expectedDebt
    ) internal {
        (uint256 collateral, uint256 debt) = _getCollateralAndDebt(_protocolId);
        string memory protocolName = _protocolIdToString(_protocolId);

        assertApproxEqAbs(collateral, _expectedCollateral, 1, string(abi.encodePacked("collateral on ", protocolName)));
        assertApproxEqAbs(debt, _expectedDebt, 1, string(abi.encodePacked("debt on ", protocolName)));
    }

    function _getCollateralAndDebt(UsdcWethLendingManager.Protocol _protocolId)
        internal
        view
        returns (uint256 collateral, uint256 debt)
    {
        UsdcWethLendingManager.Protocol[] memory protocols = new UsdcWethLendingManager.Protocol[](1);
        protocols[0] = _protocolId;
        scUSDCv2.LendingPositionInfo[] memory loanInfo = vault.getLendingPositionsInfo(protocols);

        collateral = loanInfo[0].collateral;
        debt = loanInfo[0].debt;
    }

    function _protocolIdToString(UsdcWethLendingManager.Protocol _protocolId) public pure returns (string memory) {
        if (_protocolId == UsdcWethLendingManager.Protocol.AAVE_V3) {
            return "Aave v3";
        } else if (_protocolId == UsdcWethLendingManager.Protocol.AAVE_V2) {
            return "Aave v2";
        } else if (_protocolId == UsdcWethLendingManager.Protocol.EULER) {
            return "Euler";
        }

        revert("unknown protocol id");
    }
}
