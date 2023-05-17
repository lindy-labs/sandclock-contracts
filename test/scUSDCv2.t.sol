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
import {scUSDCv2, AaveV2Adapter, AaveV3Adapter, EulerAdapter} from "../src/steth/scUSDCv2.sol";
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
    event EulerRewardsSold(uint256 eulerSold, uint256 usdcReceived);

    // after the exploit, the euler protocol was disabled. At one point it should work again, so having the
    // tests run in both cases (when protocol is working and not) requires two blocks to fork from
    uint256 constant BLOCK_BEFORE_EULER_EXPLOIT = 16816801; // Mar-13-2023 04:50:47 AM +UTC before euler hack
    uint256 constant BLOCK_AFTER_EULER_EXPLOIT = 17243956;

    uint256 constant EUL_SWAP_BLOCK = 16744453; // block at which EUL->USDC swap data was fetched
    uint256 constant EUL_AMOUNT = 1_000e18;
    // data obtained from 0x api for swapping 1000 eul for ~7883 usdc
    // https://api.0x.org/swap/v1/quote?buyToken=USDC&sellToken=0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b&sellAmount=1000000000000000000000
    bytes constant EUL_SWAP_DATA =
        hex"6af479b2000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000003635c9adc5dea0000000000000000000000000000000000000000000000000000000000001d16e269100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000042d9fcd98c322942075a5c3860693e9f4f03aae07b002710c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000064a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000e6464241aa64013c9d";
    uint256 constant EUL_SWAP_USDC_RECEIVED = 7883_963202;

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);

    WETH weth;
    ERC20 usdc;

    UsdcWethLendingManager lendingManager;
    scWETH wethVault;
    scUSDCv2 vault;

    function _setUpForkAtBlock(uint256 _forkAtBlock) internal {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(_forkAtBlock);

        usdc = ERC20(C.USDC);
        weth = WETH(payable(C.WETH));

        _deployLendingManager();
        _deployScWeth();
        _deployAndSetUpVault();
    }

    /// #constructor ///

    function test_constructor() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        assertEq(address(vault.asset()), address(usdc));
        assertEq(address(vault.scWETH()), address(wethVault));

        // check approvals
        assertEq(
            usdc.allowance(address(vault), address(lendingManager.aaveV3Pool())),
            type(uint256).max,
            "usdc->aave v3 allowance"
        );
        assertEq(usdc.allowance(address(vault), address(lendingManager.eulerProtocol())), 0, "usdc->euler allowance");
        assertEq(
            usdc.allowance(address(vault), address(lendingManager.aaveV2Pool())),
            type(uint256).max,
            "usdc->aave v2 allowance"
        );

        assertEq(
            weth.allowance(address(vault), address(lendingManager.aaveV3Pool())),
            type(uint256).max,
            "weth->aave v3 allowance"
        );
        assertEq(weth.allowance(address(vault), address(lendingManager.eulerProtocol())), 0, "weth->euler allowance");
        assertEq(
            weth.allowance(address(vault), address(lendingManager.aaveV2Pool())),
            type(uint256).max,
            "weth->aave v2 allowance"
        );

        assertEq(
            weth.allowance(address(vault), address(vault.swapRouter())), type(uint256).max, "weth->swapRouter allowance"
        );
        assertEq(weth.allowance(address(vault), address(vault.scWETH())), type(uint256).max, "weth->scWETH allowance");
    }

    /// #enableEuler ///
    function test_enableEuler_FailsIfCallerIsNotAdmin() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        vm.prank(alice);
        vm.expectRevert(CallerNotAdmin.selector);
        vault.enableEuler();
    }

    function test_enableEuler_SetsApprovalsAndEntersMarket() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);

        vault.enableEuler();

        assertEq(
            usdc.allowance(address(vault), address(lendingManager.eulerProtocol())),
            type(uint256).max,
            "usdc->euler allowance"
        );
        assertEq(
            weth.allowance(address(vault), address(lendingManager.eulerProtocol())),
            type(uint256).max,
            "weth->euler allowance"
        );

        address[] memory markets = IEulerMarkets(lendingManager.eulerMarkets()).getEnteredMarkets(address(vault));
        assertEq(markets.length, 1, "markets length");
        assertEq(markets[0], address(vault.asset()), "market asset");
    }

    function test_enableEuler_FailsIfCannotEnterEulerMarkets() public {
        // after the exploit "enterMarkets" function reverts since the protocol is down
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);

        vm.expectRevert();
        vault.enableEuler();
    }

    /// #setUsdcToEthPriceFeed

    function test_setUsdcToEthPriceFeed_FailsIfCallerIsNotAdmin() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        vm.prank(alice);
        vm.expectRevert(CallerNotAdmin.selector);
        vault.setUsdcToEthPriceFeed(AggregatorV3Interface(address(0)));
    }

    function test_setUsdcToEthPriceFeed_FailsIfNewPriceFeedIsZeroAddress() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        vm.expectRevert(PriceFeedZeroAddress.selector);
        vault.setUsdcToEthPriceFeed(AggregatorV3Interface(address(0)));
    }

    function test_setUsdcToEthPriceFeed_ChangesThePriceFeed() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        AggregatorV3Interface _newPriceFeed = AggregatorV3Interface(address(0x1));
        vault.setUsdcToEthPriceFeed(_newPriceFeed);

        assertEq(address(vault.usdcToEthPriceFeed()), address(_newPriceFeed), "price feed has not changed");
    }

    /// #rebalance ///

    function test_rebalance_FailsIfCallerIsNotKeeper() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance, true, 0);

        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.rebalance(params);
    }

    function test_rebalance_BorrowOnlyOnAaveV3() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
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
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.EULER, initialBalance, true, initialDebt);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), initialDebt, 1, "total debt");

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3, 0, 0);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.EULER, initialBalance, initialDebt);
    }

    function test_rebalance_BorrowOnlyOnAaveV2() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, true, initialDebt);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), initialDebt, 1, "total debt");

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, initialDebt);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3, 0, 0);
    }

    function test_rebalance2_BorrowOnlyOnAaveV2() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 250 ether;
        deal(address(usdc), address(vault), initialBalance * 2);

        bytes[] memory callData = new bytes[](4);
        callData[0] = abi.encodeWithSelector(scUSDCv2.supply.selector, 1, initialBalance);
        callData[1] = abi.encodeWithSelector(scUSDCv2.borrow.selector, 1, initialDebt);
        callData[2] = abi.encodeWithSelector(scUSDCv2.supply.selector, 2, initialBalance);
        callData[3] = abi.encodeWithSelector(scUSDCv2.borrow.selector, 2, initialDebt);

        vault.rebalance2(callData);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance * 2, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), initialDebt * 2, 1, "total debt");

        uint256 collateral = lendingManager.getCollateral(UsdcWethLendingManager.Protocol.AAVE_V3, address(vault));
        console2.log("collateral test", collateral);

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance, initialDebt);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, initialDebt);

        // disinvest
        // uint256 invested = vault.wethInvested();
        // console2.log("invested", invested);
        // vault.disinvest(invested);
        // uint256 wethBalance = weth.balanceOf(address(vault));
        // console2.log("wethBalance", wethBalance);

        callData = new bytes[](3);
        callData[0] = abi.encodeWithSelector(scUSDCv2.disinvest.selector, initialDebt);
        callData[1] = abi.encodeWithSelector(scUSDCv2.repay.selector, 1, initialDebt);
        callData[2] = abi.encodeWithSelector(scUSDCv2.withdraw.selector, 1, initialBalance);
        vault.rebalance2(callData);

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3, 0, 0);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, initialDebt);

        assertEq(usdc.balanceOf(address(vault)), initialBalance, "balance");

        // add euler
        EulerAdapter eulerAdapter = new EulerAdapter();
        vault.addAdapter(eulerAdapter);
        callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scUSDCv2.supply.selector, 3, initialBalance);
        callData[1] = abi.encodeWithSelector(scUSDCv2.borrow.selector, 3, initialDebt);

        vault.rebalance2(callData);

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3, 0, 0);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, initialDebt);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.EULER, initialBalance, initialDebt);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance * 2, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), initialDebt * 2, 1, "total debt");
    }

    function test_rebalance_OneProtocolLeverageDown() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
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

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, initialDebt / 2);
    }

    function test_rebalance_OneProtocolLeverageUp() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
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

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, initialDebt * 3 / 2);
    }

    function test_rebalance_OneProtocolWithAdditionalDeposits() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
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
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        uint256 initialBalance = 1_000_000e6;
        uint256 debtOnAaveV3 = 200 ether;
        uint256 debtOnAaveV2 = 200 ether;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](2);
        params[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 2, true, debtOnAaveV3);
        params[1] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance / 2, true, debtOnAaveV2);

        vault.rebalance(params);

        assertApproxEqAbs(vault.totalCollateral(), initialBalance, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), debtOnAaveV3 + debtOnAaveV2, 1, "total debt");

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 2, debtOnAaveV3);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance / 2, debtOnAaveV2);
    }

    function test_rebalance_TwoProtocolsWithAdditionalDeposits() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

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
            lendingManager.getTotalCollateral(address(vault)),
            initialBalance + additionalCollateralOnAaveV3 + additionalCollateralOnEuler,
            2,
            "total collateral after"
        );
        assertApproxEqAbs(
            lendingManager.getTotalDebt(address(vault)),
            debtOnAaveV3 + debtOnEuler + additionalDebtOnAaveV3 + additionalDebtOnEuler,
            2,
            "total debt after"
        );

        _assertCollateralAndDebt(
            UsdcWethLendingManager.Protocol.AAVE_V3,
            initialBalance / 2 + additionalCollateralOnAaveV3,
            debtOnAaveV3 + additionalDebtOnAaveV3
        );
        _assertCollateralAndDebt(
            UsdcWethLendingManager.Protocol.EULER,
            initialBalance / 2 + additionalCollateralOnEuler,
            debtOnEuler + additionalDebtOnEuler
        );
    }

    function test_rebalance_TwoProtocolsLeveragingUpAndDown() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

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
            2,
            "total collateral after"
        );
        assertApproxEqAbs(
            vault.totalDebt(),
            debtOnAaveV3 + debtOnEuler + additionalDebtOnAaveV3 - debtReductionOnEuler,
            2,
            "total debt after"
        );

        _assertCollateralAndDebt(
            UsdcWethLendingManager.Protocol.AAVE_V3,
            initialBalance / 2 + additionalCollateralOnAaveV3,
            debtOnAaveV3 + additionalDebtOnAaveV3
        );
        _assertCollateralAndDebt(
            UsdcWethLendingManager.Protocol.EULER,
            initialBalance / 2 + additionalCollateralOnEuler,
            debtOnEuler - debtReductionOnEuler
        );
    }

    function test_rebalance_ThreeProtocols() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

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

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 3, debtOnAaveV3);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance / 3, debtOnAaveV2);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.EULER, initialBalance / 3, debtOnEuler);
    }

    function test_rebalance_ThreeProtocolsLeveragingDown() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

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

        _assertCollateralAndDebt(
            UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance / 3, debtOnAaveV3 - debtReductionOnAaveV3
        );
        _assertCollateralAndDebt(
            UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance / 3, debtOnAaveV2 - debtReductionOnAaveV2
        );
        _assertCollateralAndDebt(
            UsdcWethLendingManager.Protocol.EULER, initialBalance / 3, debtOnEuler - debtReductionOnEuler
        );
    }

    function test_rebalance_EmitsEventForEachProtocol() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

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

    function test_rebalance_EnforcesFloatAmountToRemainInVault() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
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

    /// #reallocate ///

    function test_reallocate_FailsIfCallerIsNotKeeper() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        scUSDCv2.ReallocationParams[] memory reallocateParams = new scUSDCv2.ReallocationParams[](1);

        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.reallocate(reallocateParams, 0);
    }

    function test_reallocate_FailsIfFlashLoanParameterIsZero() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        scUSDCv2.ReallocationParams[] memory reallocateParams = new scUSDCv2.ReallocationParams[](1);

        vm.expectRevert(FlashLoanAmountZero.selector);
        vault.reallocate(reallocateParams, 0);
    }

    function test_reallocate_MoveEverythingFromOneProtocolToAnother() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

        uint256 totalCollateral = 1_000_000e6;
        uint256 totalDebt = 100 ether;
        deal(address(usdc), address(vault), totalCollateral);

        scUSDCv2.RebalanceParams[] memory rebalanceParams = new scUSDCv2.RebalanceParams[](1);
        rebalanceParams[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral, true, 100 ether);

        vault.rebalance(rebalanceParams);

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "total collateral before");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "total debt before");

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral, totalDebt);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V2, 0, 0);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.EULER, 0, 0);

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
        vault.reallocate(reallocateParams, flashLoanAmount);

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "total collateral after");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "total debt after");

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3, 0, 0);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V2, 0, 0);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.EULER, totalCollateral, totalDebt);
    }

    function test_reallocate_FailsIfThereIsNoDownsizeOnAtLeastOnProtocol() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

        uint256 totalCollateral = 1_000_000e6;
        uint256 totalDebt = 100 ether;
        deal(address(usdc), address(vault), totalCollateral);

        scUSDCv2.RebalanceParams[] memory rebalanceParams = new scUSDCv2.RebalanceParams[](1);
        rebalanceParams[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral, true, 100 ether);

        vault.rebalance(rebalanceParams);

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "total collateral before");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "total debt before");

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral, totalDebt);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V2, 0, 0);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.EULER, 0, 0);

        // move everything from Aave to Euler
        uint256 collateralToMove = totalCollateral / 2;
        uint256 debtToMove = totalDebt / 2;
        scUSDCv2.ReallocationParams[] memory reallocateParams = new scUSDCv2.ReallocationParams[](1);
        reallocateParams[0] = scUSDCv2.ReallocationParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            isDownsize: false,
            collateralAmount: collateralToMove,
            debtAmount: debtToMove
        });

        uint256 flashLoanAmount = debtToMove;
        vm.expectRevert();
        vault.reallocate(reallocateParams, flashLoanAmount);
    }

    function test_reallocate_MoveHalfFromOneProtocolToAnother() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

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

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral / 2, totalDebt / 2);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V2, 0, 0);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.EULER, totalCollateral / 2, totalDebt / 2);

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
        vault.reallocate(reallocateParams, flashLoanAmount);

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "total collateral after");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "total debt after");

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral / 4, totalDebt / 4);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V2, 0, 0);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.EULER, totalCollateral * 3 / 4, totalDebt * 3 / 4);
    }

    function test_reallocate_EmitsEventForEveryAffectedProtocol() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

        uint256 totalCollateral = 1_000_000e6;
        uint256 totalDebt = 100 ether;
        deal(address(usdc), address(vault), totalCollateral);

        scUSDCv2.RebalanceParams[] memory rebalanceParams = new scUSDCv2.RebalanceParams[](1);
        rebalanceParams[0] =
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral, true, totalDebt);

        vault.rebalance(rebalanceParams);

        // move half from Aave v3 to Euler and Aave v2 equally
        uint256 collateralToMoveFromAaveV3 = totalCollateral / 2;
        uint256 collateralToMoveToAaveV2 = collateralToMoveFromAaveV3 / 2;
        uint256 collateralToMoveToEuler = collateralToMoveFromAaveV3 / 2;
        uint256 debtToMoveFromAaveV3 = totalDebt / 2;
        uint256 debtToMoveToAaveV2 = debtToMoveFromAaveV3 / 2;
        uint256 debtToMoveToEuler = debtToMoveFromAaveV3 / 2;

        scUSDCv2.ReallocationParams[] memory reallocateParams = new scUSDCv2.ReallocationParams[](3);
        reallocateParams[0] = scUSDCv2.ReallocationParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V3,
            isDownsize: true,
            collateralAmount: collateralToMoveFromAaveV3,
            debtAmount: debtToMoveFromAaveV3
        });
        reallocateParams[1] = scUSDCv2.ReallocationParams({
            protocolId: UsdcWethLendingManager.Protocol.EULER,
            isDownsize: false,
            collateralAmount: collateralToMoveToEuler,
            debtAmount: debtToMoveToEuler
        });
        reallocateParams[2] = scUSDCv2.ReallocationParams({
            protocolId: UsdcWethLendingManager.Protocol.AAVE_V2,
            isDownsize: false,
            collateralAmount: collateralToMoveToAaveV2,
            debtAmount: debtToMoveToAaveV2
        });

        uint256 flashLoanAmount = debtToMoveFromAaveV3;
        vm.expectEmit(true, true, true, true);
        emit Reallocated(
            UsdcWethLendingManager.Protocol.AAVE_V3, true, collateralToMoveFromAaveV3, debtToMoveFromAaveV3
        );
        emit Reallocated(UsdcWethLendingManager.Protocol.AAVE_V2, false, collateralToMoveToAaveV2, debtToMoveToAaveV2);
        emit Reallocated(UsdcWethLendingManager.Protocol.EULER, false, collateralToMoveToEuler, debtToMoveToEuler);

        vault.reallocate(reallocateParams, flashLoanAmount);
    }

    function test_reallocate_WorksWhenCalledMultipleTimes() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

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
        vault.reallocate(reallocateParams, flashLoanAmount);

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
        vault.reallocate(reallocateParams, flashLoanAmount);

        assertApproxEqAbs(vault.totalCollateral(), totalCollateral, 1, "total collateral");
        assertApproxEqAbs(vault.totalDebt(), totalDebt, 1, "total debt");

        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3, totalCollateral, totalDebt);
        _assertCollateralAndDebt(UsdcWethLendingManager.Protocol.EULER, 0, 0);
    }

    // #receiveFlashLoan ///

    function test_receiveFlashLoan_FailsIfCallerIsNotBalancerVault() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory feeAmounts = new uint256[](1);

        vm.expectRevert(InvalidFlashLoanCaller.selector);
        vault.receiveFlashLoan(tokens, amounts, feeAmounts, "");
    }

    function test_receiveFlashLoan_FailsIfInitiatorIsNotVault() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
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
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.sellProfit(0);
    }

    function test_sellProfit_FailsIfProfitsAre0() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vm.prank(keeper);
        vm.expectRevert(NoProfitsToSell.selector);
        vault.sellProfit(0);
    }

    function test_sellProfit_DisinvestsAndDoesNotChageCollateralOrDebt() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

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
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

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
        emit ProfitSold(profit, 161501_703508);
        vm.prank(keeper);
        vault.sellProfit(0);
    }

    function test_sellProfit_FailsIfAmountReceivedIsLeessThanAmountOutMin() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

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
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
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
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
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
            UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance.mulWadDown(1e18 - floatPercentage), true, 200 ether
        );

        vault.rebalance(params);

        uint256 collateralBefore = lendingManager.getCollateral(UsdcWethLendingManager.Protocol.AAVE_V3, address(vault));
        uint256 debtBefore = lendingManager.getDebt(UsdcWethLendingManager.Protocol.AAVE_V3, address(vault));

        uint256 withdrawAmount = usdc.balanceOf(address(vault));
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(usdc.balanceOf(alice), withdrawAmount, "alice usdc balance");
        assertEq(vault.totalCollateral(), collateralBefore, "collateral not expected to change");
        assertEq(vault.totalDebt(), debtBefore, "total debt not expected to change");
    }

    function test_withdraw_PullsFundsFromSellingProfitSecond() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
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
            UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance.mulWadDown(1e18 - floatPercentage), true, 200 ether
        );

        vault.rebalance(params);

        // add 100% profit to the weth vault
        uint256 initialWethInvested = vault.wethInvested();
        deal(address(weth), address(wethVault), initialWethInvested * 2);

        uint256 collateralBefore = vault.totalCollateral();
        uint256 debtBefore = vault.totalDebt();

        uint256 profit = vault.getProfit();
        uint256 expectedUsdcFromProfitSelling = vault.getUsdcFromWeth(profit);
        uint256 initialFloat = vault.usdcBalance();
        // withdraw double the float amount
        uint256 withdrawAmount = initialFloat * 2;
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(usdc.balanceOf(alice), withdrawAmount, "alice usdc balance");
        assertApproxEqAbs(vault.getProfit(), 0, 1, "profit not sold");
        assertApproxEqAbs(vault.totalCollateral(), collateralBefore, 1, "collateral not expected to change");
        assertApproxEqAbs(vault.totalDebt(), debtBefore, 1, "debt not expected to change");
        assertApproxEqRel(vault.usdcBalance(), expectedUsdcFromProfitSelling - initialFloat, 0.01e18, "float remaining");
    }

    function test_withdraw_PullsFundsFromInvestedWhenFloatAndProfitSellingIsNotEnough() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
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
            UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance.mulWadDown(1e18 - floatPercentage), true, 200 ether
        );

        vault.rebalance(params);

        // add 50% profit to the weth vault
        uint256 initialWethInvested = vault.wethInvested();
        deal(address(weth), address(wethVault), initialWethInvested.mulWadDown(1.5e18));

        uint256 totalAssetsBefore = vault.totalAssets();

        uint256 withdrawAmount = vault.convertToAssets(vault.balanceOf(alice));
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(usdc.balanceOf(alice), withdrawAmount, "alice usdc balance");
        assertApproxEqAbs(vault.getProfit(), 0, 1, "profit not sold");
        assertTrue(vault.totalAssets().divWadDown(totalAssetsBefore) < 0.005e18, "too much leftovers");
    }

    function test_withdraw_PullsFundsFromAllProtocolsInEqualWeight() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

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
            _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance / 2, true, initialDebt / 2);

        vault.rebalance(params);

        uint256 withdrawAmount = initialBalance / 2;
        uint256 endCollateral = initialBalance / 2;
        uint256 endDebt = initialDebt / 2;
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);
        console2.log("withdraw complete");

        assertApproxEqRel(usdc.balanceOf(alice), withdrawAmount, 0.01e18, "alice usdc balance");

        assertApproxEqRel(vault.totalCollateral(), endCollateral, 0.01e18, "total collateral");
        assertApproxEqRel(vault.totalDebt(), endDebt, 0.01e18, "total debt");

        (uint256 collateralOnAaveV3, uint256 debtOnAaveV3) =
            _getCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V3);
        (uint256 collateralAaveV2, uint256 debtOnAaveV2) =
            _getCollateralAndDebt(UsdcWethLendingManager.Protocol.AAVE_V2);

        assertApproxEqRel(collateralOnAaveV3, endCollateral / 2, 0.01e18, "collateral on aave v3");
        assertApproxEqRel(collateralAaveV2, endCollateral / 2, 0.01e18, "collateral on euler");
        assertApproxEqRel(debtOnAaveV3, endDebt / 2, 0.01e18, "debt on aave v3");
        assertApproxEqRel(debtOnAaveV2, endDebt / 2, 0.01e18, "debt on euler");
    }

    /// #exitAllPositions ///

    function test_exitAllPositions_FailsIfCallerNotAdmin() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        vm.prank(alice);
        vm.expectRevert(CallerNotAdmin.selector);
        vault.exitAllPositions(0);
    }

    function test_exitAllPositions_FailsIfVaultIsNotUnderawater() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, true, 200 ether);

        vault.rebalance(params);

        vm.expectRevert(VaultNotUnderwater.selector);
        vault.exitAllPositions(0);
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralOnOneProtocol() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V2, initialBalance, true, 200 ether);

        vault.rebalance(params);

        // simulate 50% loss
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested / 2);

        uint256 totalBefore = vault.totalAssets();

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        vault.exitAllPositions(0);

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        assertApproxEqRel(vault.usdcBalance(), totalBefore, 0.01e18, "vault usdc balance");
        assertEq(vault.totalCollateral(), 0, "vault collateral");
        assertEq(vault.totalDebt(), 0, "vault debt");
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralOnAllProtocols() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

        uint256 initialCollateralPerProtocol = 500_000e6;
        uint256 initialDebtPerProtocol = 100 ether;
        deal(address(usdc), address(vault), initialCollateralPerProtocol * 3);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](3);
        params[0] = _createRebalanceParams(
            UsdcWethLendingManager.Protocol.AAVE_V3, initialCollateralPerProtocol, true, initialDebtPerProtocol
        );
        params[1] = _createRebalanceParams(
            UsdcWethLendingManager.Protocol.AAVE_V2, initialCollateralPerProtocol, true, initialDebtPerProtocol
        );
        params[2] = _createRebalanceParams(
            UsdcWethLendingManager.Protocol.EULER, initialCollateralPerProtocol, true, initialDebtPerProtocol
        );

        vault.rebalance(params);

        // simulate 50% loss
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested / 2);

        uint256 totalBefore = vault.totalAssets();

        vault.exitAllPositions(0);

        assertApproxEqRel(vault.usdcBalance(), totalBefore, 0.01e18, "vault usdc balance");
        assertEq(vault.totalCollateral(), 0, "vault collateral");
        assertEq(vault.totalDebt(), 0, "vault debt");
    }

    function test_exitAllPositions_EmitsEventOnSuccess() public {
        _setUpForkAtBlock(BLOCK_BEFORE_EULER_EXPLOIT);
        vault.enableEuler();

        uint256 initialCollateralPerProtocol = 500_000e6;
        uint256 initialDebtPerProtocol = 100 ether;
        deal(address(usdc), address(vault), initialCollateralPerProtocol * 3);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](3);
        params[0] = _createRebalanceParams(
            UsdcWethLendingManager.Protocol.AAVE_V3, initialCollateralPerProtocol, true, initialDebtPerProtocol
        );
        params[1] = _createRebalanceParams(
            UsdcWethLendingManager.Protocol.AAVE_V2, initialCollateralPerProtocol, true, initialDebtPerProtocol
        );
        params[2] = _createRebalanceParams(
            UsdcWethLendingManager.Protocol.EULER, initialCollateralPerProtocol, true, initialDebtPerProtocol
        );

        vault.rebalance(params);

        // simulate 50% loss
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested / 2);

        uint256 invested = vault.wethInvested();
        uint256 debt = vault.totalDebt();
        uint256 collateral = vault.totalCollateral();

        vm.expectEmit(true, true, true, true);
        emit EmergencyExitExecuted(address(this), invested, debt, collateral);
        vault.exitAllPositions(0);
    }

    function test_exitAllPositions_FailsIfEndBalanceIsLowerThanMin() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        uint256 initialBalance = 1_000_000e6;
        deal(address(usdc), address(vault), initialBalance);

        scUSDCv2.RebalanceParams[] memory params = new scUSDCv2.RebalanceParams[](1);
        params[0] = _createRebalanceParams(UsdcWethLendingManager.Protocol.AAVE_V3, initialBalance, true, 200 ether);

        vault.rebalance(params);

        // simulate 50% loss
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested / 2);

        uint256 invalidEndUsdcBalanceMin = vault.totalAssets().mulWadDown(1.05e18);

        vm.expectRevert(EndUsdcBalanceTooLow.selector);
        vault.exitAllPositions(invalidEndUsdcBalanceMin);
    }

    /// #sellEulerRewards ///

    function test_sellEulerRewards_FailsIfCallerIsNotKeeper() public {
        _setUpForkAtBlock(EUL_SWAP_BLOCK);
        vm.startPrank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.sellEulerRewards(bytes("0"), 0);
    }

    function test_sellEulerRewards_SwapsEulerForUsdc() public {
        _setUpForkAtBlock(EUL_SWAP_BLOCK);

        uint256 initialUsdcBalance = 2_000e6;
        deal(address(usdc), address(vault), initialUsdcBalance);
        deal(address(lendingManager.eulerRewardsToken()), address(vault), EUL_AMOUNT * 2);

        assertEq(lendingManager.eulerRewardsToken().balanceOf(address(vault)), EUL_AMOUNT * 2, "euler balance");
        assertEq(vault.usdcBalance(), initialUsdcBalance, "usdc balance");
        assertEq(vault.totalAssets(), initialUsdcBalance, "total assets");

        vault.sellEulerRewards(EUL_SWAP_DATA, 0);

        assertEq(lendingManager.eulerRewardsToken().balanceOf(address(vault)), EUL_AMOUNT, "vault euler balance");
        assertEq(vault.totalAssets(), initialUsdcBalance + EUL_SWAP_USDC_RECEIVED, "vault total assets");
        assertEq(vault.usdcBalance(), initialUsdcBalance + EUL_SWAP_USDC_RECEIVED, "vault usdc balance");
        assertEq(
            lendingManager.eulerRewardsToken().allowance(address(vault), lendingManager.zeroExRouter()),
            0,
            "0x eul allowance"
        );
    }

    function test_sellEulerRewards_EmitsEventOnSuccessfulSwap() public {
        _setUpForkAtBlock(EUL_SWAP_BLOCK);

        deal(address(lendingManager.eulerRewardsToken()), address(vault), EUL_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit EulerRewardsSold(EUL_AMOUNT, EUL_SWAP_USDC_RECEIVED);

        vault.sellEulerRewards(EUL_SWAP_DATA, 0);
    }

    function test_sellEulerRewards_FailsIfUsdcAmountReceivedIsLessThanMin() public {
        _setUpForkAtBlock(EUL_SWAP_BLOCK);

        deal(address(lendingManager.eulerRewardsToken()), address(vault), EUL_AMOUNT);

        vm.expectRevert(AmountReceivedBelowMin.selector);
        vault.sellEulerRewards(EUL_SWAP_DATA, EUL_SWAP_USDC_RECEIVED + 1);
    }

    function test_sellEulerRewards_FailsIfSwapIsNotSucessful() public {
        _setUpForkAtBlock(EUL_SWAP_BLOCK);

        deal(address(lendingManager.eulerRewardsToken()), address(vault), EUL_AMOUNT);

        bytes memory invalidSwapData = hex"6af479b20000";

        vm.expectRevert(EulerSwapFailed.selector);
        vault.sellEulerRewards(invalidSwapData, 0);
    }

    /// #setSlippageTolerance ///

    function test_setSlippageTolerance_FailsIfCallerIsNotAdmin() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        uint256 tolerance = 0.01e18;

        vm.startPrank(alice);
        vm.expectRevert(CallerNotAdmin.selector);
        vault.setSlippageTolerance(tolerance);
    }

    function test_setSlippageTolerance_FailsIfSlippageToleranceGreaterThanOne() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        uint256 tolerance = 1e18 + 1;

        vm.expectRevert(InvalidSlippageTolerance.selector);
        vault.setSlippageTolerance(tolerance);
    }

    function test_setSlippageTolearnce_UpdatesSlippageTolerance() public {
        _setUpForkAtBlock(BLOCK_AFTER_EULER_EXPLOIT);
        uint256 newTolerance = 0.01e18;

        vm.expectEmit(true, true, true, true);
        emit SlippageToleranceUpdated(address(this), newTolerance);

        vault.setSlippageTolerance(newTolerance);

        assertEq(vault.slippageTolerance(), newTolerance, "slippage tolerance");
    }

    /// internal helper functions ///

    function _deployLendingManager() internal {
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

    function _deployScWeth() internal {
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
    }

    function _deployAndSetUpVault() internal {
        scUSDCv2.ConstructorParams memory params = scUSDCv2.ConstructorParams({
            admin: address(this),
            keeper: keeper,
            scWETH: wethVault,
            lendingManager: lendingManager,
            usdc: ERC20(C.USDC),
            weth: WETH(payable(C.WETH)),
            uniswapSwapRouter: ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER),
            chainlinkUsdcToEthPriceFeed: AggregatorV3Interface(C.CHAINLINK_USDC_ETH_PRICE_FEED),
            balancerVault: IVault(C.BALANCER_VAULT)
        });

        vault = new scUSDCv2(params);

        // set vault eth balance to zero
        vm.deal(address(vault), 0);
        // set float percentage to 0 for most tests
        vault.setFloatPercentage(0);
        // assign keeper role to deployer
        vault.grantRole(vault.KEEPER_ROLE(), address(this));
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

    function _assertCollateralAndDebt(
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
        collateral = lendingManager.getCollateral(_protocolId, address(vault));
        debt = lendingManager.getDebt(_protocolId, address(vault));
    }

    function _protocolIdToString(UsdcWethLendingManager.Protocol _protocolId) public pure returns (string memory) {
        if (_protocolId == UsdcWethLendingManager.Protocol.AAVE_V3) {
            return "Aave v3";
        } else if (_protocolId == UsdcWethLendingManager.Protocol.AAVE_V2) {
            return "Aave v2";
        } else {
            return "Euler";
        }
    }
}
