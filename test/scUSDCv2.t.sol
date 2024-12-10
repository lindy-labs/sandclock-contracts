// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {Errors} from "openzeppelin-contracts/utils/Errors.sol";

import {IAdapter} from "../src/steth/IAdapter.sol";
import {scUSDCv2} from "../src/steth/scUSDCv2.sol";
import {AaveV2ScUsdcAdapter} from "../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";

import "../src/errors/scErrors.sol";
import {Constants as C} from "../src/lib/Constants.sol";
import {scWETH} from "../src/steth/scWETH.sol";
import {AggregatorV3Interface} from "../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {UsdcWethPriceConverter} from "../src/steth/priceConverter/UsdcWethPriceConverter.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {IProtocolFeesCollector} from "../src/interfaces/balancer/IProtocolFeesCollector.sol";
import {FaultyAdapter} from "./mocks/adapters/FaultyAdapter.sol";
import {scCrossAssetYieldVault} from "../src/steth/scCrossAssetYieldVault.sol";
import {UsdcWethSwapper} from "../src/steth/swapper/UsdcWethSwapper.sol";
import {ISwapper} from "../src/steth/swapper/ISwapper.sol";
import {UniversalSwapper} from "../src/steth/swapper/UniversalSwapper.sol";

contract scUSDCv2Test is Test {
    using FixedPointMathLib for uint256;

    event ProtocolAdapterAdded(address indexed admin, uint256 adapterId, address adapter);
    event ProtocolAdapterRemoved(address indexed admin, uint256 adapterId);
    event SlippageToleranceUpdated(address indexed admin, uint256 newSlippageTolerance);
    event EmergencyExitExecuted(
        address indexed admin, uint256 wethWithdrawn, uint256 debtRepaid, uint256 collateralReleased
    );
    event Reallocated();
    event Rebalanced(uint256 totalCollateral, uint256 totalDebt, uint256 floatBalance);
    event ProfitSold(uint256 wethSold, uint256 usdcReceived);
    event TokenSwapped(address tokenIn, address tokenOut, uint256 amountSold, uint256 usdcReceived);
    event Supplied(uint256 adapterId, uint256 amount);
    event Borrowed(uint256 adapterId, uint256 amount);
    event Repaid(uint256 adapterId, uint256 amount);
    event Withdrawn(uint256 adapterId, uint256 amount);
    event Disinvested(uint256 wethAmount);
    event RewardsClaimed(uint256 adapterId);
    event SwapperUpdated(address indexed admin, ISwapper newSwapper);
    event PriceConverterUpdated(address indexed admin, address newPriceConverter);
    event TargetVaultUpdated(address newTargetVault);

    uint256 constant EUL_SWAP_BLOCK = 16744453; // block at which EUL->USDC swap data was fetched
    uint256 constant EUL_AMOUNT = 1_000e18;
    // data obtained from 0x api for swapping 1000 eul for ~7883 usdc
    // https://api.0x.org/swap/v1/quote?buyToken=USDC&sellToken=0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b&sellAmount=1000000000000000000000
    bytes constant EUL_SWAP_DATA =
        hex"6af479b2000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000003635c9adc5dea0000000000000000000000000000000000000000000000000000000000001d16e269100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000042d9fcd98c322942075a5c3860693e9f4f03aae07b002710c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000064a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48000000000000000000000000000000000000000000000000000000000000869584cd00000000000000000000000010000000000000000000000000000000000000110000000000000000000000000000000000000000000000e6464241aa64013c9d";
    uint256 constant EUL_SWAP_USDC_RECEIVED = 7883_963202;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);

    WETH weth;
    ERC20 usdc;

    scWETH wethVault;
    scUSDCv2 vault;
    AaveV3ScUsdcAdapter aaveV3;
    AaveV2ScUsdcAdapter aaveV2;
    MorphoAaveV3ScUsdcAdapter morpho;
    UsdcWethSwapper swapper;
    UsdcWethPriceConverter priceConverter;

    constructor() Test() {
        vm.createSelectFork(vm.envString("RPC_URL_MAINNET"));
        _setUpForkAtBlock(17529069);

        usdc = ERC20(C.USDC);
        weth = WETH(payable(C.WETH));
    }

    function _setUpForkAtBlock(uint256 _forkAtBlock) internal {
        vm.rollFork(_forkAtBlock);

        aaveV3 = new AaveV3ScUsdcAdapter();
        aaveV2 = new AaveV2ScUsdcAdapter();
        morpho = new MorphoAaveV3ScUsdcAdapter();

        _deployScWeth();
        _deployAndSetUpVault();
    }

    /// #constructor ///

    function test_constructor() public {
        assertEq(address(vault.asset()), C.USDC);
        assertEq(address(vault.targetVault()), address(wethVault), "weth vault");
        assertEq(address(vault.priceConverter()), address(priceConverter), "price converter");
        assertEq(address(vault.swapper()), address(swapper), "swapper");

        assertEq(weth.allowance(address(vault), address(vault.targetVault())), type(uint256).max, "scWETH allowance");
    }

    function test_constructor_FailsIfScWethIsZeroAddress() public {
        wethVault = scWETH(payable(0x0));

        vm.expectRevert(ZeroAddress.selector);
        new scUSDCv2(alice, keeper, wethVault, priceConverter, swapper);
    }

    function test_constructor_FailsIfPriceConverterIsZeroAddress() public {
        priceConverter = UsdcWethPriceConverter(address(0x0));

        vm.expectRevert(ZeroAddress.selector);
        new scUSDCv2(address(this), keeper, wethVault, priceConverter, swapper);
    }

    function test_constructor_FailsIfSwapperIsZeroAddress() public {
        swapper = UsdcWethSwapper(address(0x0));

        vm.expectRevert(ZeroAddress.selector);
        new scUSDCv2(address(this), keeper, wethVault, priceConverter, swapper);
    }

    /// #updateTargetVault ///

    function test_updateTargetVault_FailsIfCallerNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(CallerNotAdmin.selector);
        vault.updateTargetVault(wethVault);
    }

    function test_updateTargetVault_FailsifTargetTokenIsDifferentThanPreviousOne() public {
        ERC4626 fakeVault = new FakeTargetVault(ERC20(C.USDT));

        vm.expectRevert(TargetTokenMismatch.selector);
        vault.updateTargetVault(fakeVault);
    }

    function test_updateTargetVault_FailsIfInvestedAmountNotZero() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        _setBalance(address(vault), initialBalance);

        bytes[] memory callData = _getSupplyAndBorrowCallData(new bytes[](2), aaveV3.id(), initialBalance, initialDebt);
        vault.rebalance(callData);

        vm.expectRevert(InvestedAmountNotWithdrawn.selector);
        vault.updateTargetVault(wethVault);
    }

    function test_updateTargetVault_EmitsEvent() public {
        uint256 initialBalance = 1_000_000e6;
        uint256 initialDebt = 100 ether;
        _setBalance(address(vault), initialBalance);

        bytes[] memory callData = _getSupplyAndBorrowCallData(new bytes[](2), aaveV3.id(), initialBalance, initialDebt);
        vault.rebalance(callData);

        vault.disinvest(vault.targetTokenInvestedAmount());

        ERC4626 newTargetVault = new FakeTargetVault(weth);

        vm.expectEmit(true, true, true, true);
        emit TargetVaultUpdated(address(newTargetVault));

        vault.updateTargetVault(newTargetVault);
        assertEq(address(vault.targetVault()), address(newTargetVault), "target vault not updated");
    }

    /// #setPriceConverter ///

    function test_setPriceConverter_FailsIfCallerIsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(CallerNotAdmin.selector);
        vault.setPriceConverter(UsdcWethPriceConverter(address(0x1)));
    }

    function test_setPriceConverter_FailsIfAddressIs0() public {
        vm.expectRevert(ZeroAddress.selector);
        vault.setPriceConverter(UsdcWethPriceConverter(address(0x0)));
    }

    function test_setPriceConverter_UpdatesThePriceConverterToNewAddress() public {
        UsdcWethPriceConverter newPriceConverter = new UsdcWethPriceConverter();

        vault.setPriceConverter(newPriceConverter);

        assertEq(address(vault.priceConverter()), address(newPriceConverter), "price converter not updated");
    }

    function test_setPriceConverter_EmitsEvent() public {
        UsdcWethPriceConverter newPriceConverter = new UsdcWethPriceConverter();

        vm.expectEmit(true, true, true, true);
        emit PriceConverterUpdated(address(this), address(newPriceConverter));

        vault.setPriceConverter(newPriceConverter);
    }

    /// #setSwapper ///

    function test_setSwapper_FailsIfCallerIsNotAdmin() public {
        vm.prank(alice);
        vm.expectRevert(CallerNotAdmin.selector);
        vault.setSwapper(ISwapper(address(0x1)));
    }

    function test_setSwapper_FailsIfAddressIs0() public {
        vm.expectRevert(ZeroAddress.selector);
        vault.setSwapper(ISwapper(address(0x0)));
    }

    function test_setSwapper_UpdatesTheSwapperToNewAddress() public {
        ISwapper newSwapper = ISwapper(address(0x09));

        vault.setSwapper(newSwapper);

        assertEq(address(vault.swapper()), address(newSwapper), "swapper not updated");
    }

    function test_setSwapper_EmitsEvent() public {
        ISwapper newSwapper = ISwapper(address(0x09));

        vm.expectEmit(true, true, true, true);
        emit SwapperUpdated(address(this), newSwapper);

        vault.setSwapper(newSwapper);
    }

    /// #addAdapter ///

    function test_addAdapter_FailsIfCallerIsNotAdmin() public {
        IAdapter newAdapter = morpho;

        assertTrue(!vault.isSupported(newAdapter.id()), "morpho should not be supported");

        vm.prank(keeper);
        vm.expectRevert(CallerNotAdmin.selector);
        vault.addAdapter(newAdapter);
    }

    function test_addAdapter_NewProtocolBecomesSupported() public {
        IAdapter newAdapter = morpho;

        assertTrue(!vault.isSupported(newAdapter.id()), "morpho should not be supported");

        vault.addAdapter(newAdapter);

        assertTrue(vault.isSupported(newAdapter.id()), "morpho should be supported");
    }

    function test_addAdapter_FailsIfAlreadySupported() public {
        IAdapter newAdapter = aaveV3;

        assertTrue(vault.isSupported(newAdapter.id()), "aaveV3 should be supported initially");

        vm.expectRevert(abi.encodeWithSelector(ProtocolInUse.selector, newAdapter.id()));
        vault.addAdapter(newAdapter);
    }

    function test_addAdapter_SetsApprovalsAndEnablesInteractionWithNewProtocol() public {
        uint256 initialBalance = _setBalance(address(vault), 1000e6);

        vault.addAdapter(morpho);

        assertEq(usdc.allowance(address(vault), address(morpho.morpho())), type(uint256).max, "usdc allowance");
        assertEq(weth.allowance(address(vault), address(morpho.morpho())), type(uint256).max, "weth allowance");

        vault.supply(morpho.id(), initialBalance);
        assertEq(_usdcBalance(), 0, "usdc balance");
        assertApproxEqAbs(morpho.getCollateral(address(vault)), initialBalance, 1, "collateral");
    }

    function test_addAdapter_EmitsEvent() public {
        _setBalance(address(vault), 1000e6);

        vm.expectEmit(true, true, true, true);
        emit ProtocolAdapterAdded(address(this), morpho.id(), address(morpho));

        vault.addAdapter(morpho);
    }

    /// #removeAdapter ///

    function test_removeAdapter_FailsIfCallerIsNotAdmin() public {
        vm.prank(keeper);
        vm.expectRevert(CallerNotAdmin.selector);

        vault.removeAdapter(1, false);
    }

    function test_removeAdapter_FailsIfProtocolIsNotSupported() public {
        uint256 morphoId = morpho.id();

        vm.expectRevert(abi.encodeWithSelector(ProtocolNotSupported.selector, morphoId));
        vault.removeAdapter(morphoId, false);
    }

    function test_removeAdapter_FailsIfProtocolIsBeingUsed() public {
        uint256 intialBalance = _setBalance(address(vault), 1_000e6);
        uint256 aaveV3Id = aaveV3.id();

        vault.supply(aaveV3Id, intialBalance);

        vm.expectRevert(abi.encodeWithSelector(ProtocolInUse.selector, aaveV3Id));
        vault.removeAdapter(aaveV3Id, false);
    }

    function test_removeAdapter_RemovesSupportForProvidedProtocolId() public {
        // going to remove aave v3
        uint256 aaveV3Id = aaveV3.id();

        // the vault was set up to support aave v3 & aave v2
        assertTrue(vault.isSupported(aaveV3Id), "aave v3 should be supported");
        assertTrue(vault.isSupported(aaveV2.id()), "aave v2 should be supported");

        vault.removeAdapter(aaveV3Id, false);

        assertTrue(!vault.isSupported(aaveV3Id), "aave v3 should not be supported anymore");
        assertTrue(vault.isSupported(aaveV2.id()), "aave v2 should be supported");

        vm.expectRevert();

        uint256 usdcBalance = 1_000e6;
        deal(address(usdc), address(vault), usdcBalance);
        vm.expectRevert(abi.encodeWithSelector(ProtocolNotSupported.selector, aaveV3Id));
        vault.supply(aaveV3Id, usdcBalance);
    }

    function test_removeAdapter_ResetsUsdcAndWethApprovals() public {
        // going to remove aave v2
        uint256 aaveV2Id = aaveV2.id();

        // the vault was set up to support aave v3 & aave v2
        assertTrue(vault.isSupported(aaveV2Id), "aave v2 should be supported");

        vault.removeAdapter(aaveV2Id, false);

        assertTrue(!vault.isSupported(aaveV2Id), "aave v2 should not be supported anymore");

        assertEq(usdc.allowance(address(vault), address(aaveV2.pool())), 0, "usdc allowance");
        assertEq(weth.allowance(address(vault), address(aaveV2.pool())), 0, "weth allowance");
    }

    function test_removeAdapter_EmitsEvent() public {
        // going to remove aave v2
        uint256 aaveV2Id = aaveV2.id();

        vm.expectEmit(true, true, true, true);
        emit ProtocolAdapterRemoved(address(this), aaveV2Id);

        vault.removeAdapter(aaveV2Id, false);
    }

    function test_removeAdapter_ForceRemovesFaultyAdapters() public {
        // add faulty adapter that reverts on every interaction with the underlying protocol
        FaultyAdapter faultyAdapter = new FaultyAdapter();
        vault.addAdapter(faultyAdapter);

        assertTrue(vault.isSupported(faultyAdapter.id()), "faulty adapter should be supported");
        assertEq(usdc.allowance(address(vault), faultyAdapter.protocol()), type(uint256).max, "usdc allowance");
        assertEq(weth.allowance(address(vault), faultyAdapter.protocol()), type(uint256).max, "weth allowance");

        uint256 id = faultyAdapter.id();

        vm.expectRevert("not working");
        vault.removeAdapter(id, false);

        // works if forced
        vault.removeAdapter(id, true);

        assertEq(usdc.allowance(address(vault), faultyAdapter.protocol()), 0, "usdc allowance");
        assertEq(weth.allowance(address(vault), faultyAdapter.protocol()), 0, "weth allowance");
    }

    /// #supply ///

    function test_supply_FailsIfCallerIsNotKeeper() public {
        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.supply(1, 0);
    }

    function test_supply_FailsIfProtocolIsNotSupported() public {
        // morpho is not supported by default
        uint256 protocolId = morpho.id();

        vm.expectRevert(abi.encodeWithSelector(ProtocolNotSupported.selector, protocolId));
        vault.supply(protocolId, 1);
    }

    function test_supply_MovesAssetsToLendingProtocol() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000e6);

        vault.supply(aaveV2.id(), initialBalance);

        assertEq(aaveV2.getCollateral(address(vault)), initialBalance);
    }

    function test_supply_EmitsEvent() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000e6);

        vm.expectEmit(true, true, true, true);
        emit Supplied(aaveV3.id(), initialBalance);

        vault.supply(aaveV3.id(), initialBalance);
    }

    /// #borrow ///

    function test_borrow_FailsIfCallerIsNotKeeper() public {
        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.borrow(1, 0);
    }

    function test_borrow_FailsIfProtocolIsNotSupported() public {
        //  morpho is not supported by default
        uint256 protocolId = morpho.id();

        vm.expectRevert(abi.encodeWithSelector(ProtocolNotSupported.selector, protocolId));
        vault.borrow(protocolId, 1);
    }

    function test_borrow_CreatesLoanOnLendingProtocol() public {
        uint256 initialBalance = _setBalance(address(vault), 10_000e6);
        vault.supply(aaveV2.id(), initialBalance);

        uint256 borrowAmount = 2 ether;
        vault.borrow(aaveV2.id(), borrowAmount);

        assertEq(aaveV2.getDebt(address(vault)), borrowAmount);
    }

    function test_borrow_EmitsEvent() public {
        uint256 initialBalance = _setBalance(address(vault), 10_000e6);

        vault.supply(aaveV2.id(), initialBalance);

        uint256 borrowAmount = 2 ether;
        vm.expectEmit(true, true, true, true);
        emit Borrowed(aaveV2.id(), borrowAmount);

        vault.borrow(aaveV2.id(), borrowAmount);
    }

    // #repay ///

    function test_repay_FailsIfCallerIsNotKeeper() public {
        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.repay(1, 0);
    }

    function test_repay_FailsIfProtocolIsNotSupported() public {
        // morpho is not supported by default
        uint256 protocolId = morpho.id();

        vm.expectRevert(abi.encodeWithSelector(ProtocolNotSupported.selector, protocolId));
        vault.repay(protocolId, 1);
    }

    function test_repay_RepaysLoanOnLendingProtocol() public {
        uint256 initialBalance = _setBalance(address(vault), 10_000e6);
        uint256 borrowAmount = 2 ether;
        uint256 repayAmount = 1 ether;

        vault.supply(aaveV2.id(), initialBalance);
        vault.borrow(aaveV2.id(), borrowAmount);

        vault.repay(aaveV2.id(), repayAmount);

        assertApproxEqAbs(aaveV2.getDebt(address(vault)), borrowAmount - repayAmount, 1);
    }

    function test_repay_EmitsEvent() public {
        uint256 initialBalance = _setBalance(address(vault), 10_000e6);
        uint256 borrowAmount = 2 ether;
        uint256 repayAmount = 1 ether;

        vault.supply(aaveV2.id(), initialBalance);
        vault.borrow(aaveV2.id(), borrowAmount);

        vm.expectEmit(true, true, true, true);
        emit Repaid(aaveV2.id(), repayAmount);

        vault.repay(aaveV2.id(), repayAmount);
    }

    /// #withdraw ///

    function test_withdraw_FailsIfCallerIsNotKeeper() public {
        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.withdraw(1, 0);
    }

    function test_withdraw_FailsIfProtocolIsNotSupported() public {
        // morpho is not supported by default
        uint256 protocolId = morpho.id();

        vm.expectRevert(abi.encodeWithSelector(ProtocolNotSupported.selector, protocolId));
        vault.withdraw(protocolId, 1);
    }

    function test_withdraw_WithdrawsAssetsFromLendingProtocol() public {
        uint256 initialBalance = _setBalance(address(vault), 10_000e6);
        uint256 withdrawAmount = 5_000e6;

        vault.supply(aaveV2.id(), initialBalance);
        vault.borrow(aaveV2.id(), 1 ether);

        vault.withdraw(aaveV2.id(), withdrawAmount);

        assertEq(_usdcBalance(), withdrawAmount, "usdc balance");
        assertApproxEqAbs(aaveV2.getCollateral(address(vault)), initialBalance - withdrawAmount, 1, "collateral");
    }

    function test_withdraw_EmitsEvent() public {
        uint256 initialBalance = _setBalance(address(vault), 10_000e6);
        uint256 withdrawAmount = 5_000e6;

        vault.supply(aaveV3.id(), initialBalance);

        vm.expectEmit(true, true, true, true);
        emit Withdrawn(aaveV3.id(), withdrawAmount);

        vault.withdraw(aaveV3.id(), withdrawAmount);
    }

    /// #disinvest ///

    function test_disinvest_FailsIfCallerIsNotKeeper() public {
        deal(address(weth), address(vault), 1 ether);

        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.disinvest(1);
    }

    function test_disinvest_WithdrawsWethInvestedFromScWETH() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 initialDebt = 100 ether;
        uint256 disinvestAmount = 50 ether;

        bytes[] memory callData = _getSupplyAndBorrowCallData(new bytes[](2), aaveV3.id(), initialBalance, initialDebt);
        vault.rebalance(callData);

        vault.disinvest(disinvestAmount);

        assertEq(weth.balanceOf(address(vault)), disinvestAmount, "weth balance");
        assertEq(vault.targetTokenInvestedAmount(), initialDebt - disinvestAmount, "weth invested");
    }

    function test_disinvest_EmitsEvent() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 initialDebt = 100 ether;
        uint256 disinvestAmount = 1 ether;

        bytes[] memory callData = _getSupplyAndBorrowCallData(new bytes[](2), aaveV3.id(), initialBalance, initialDebt);
        vault.rebalance(callData);

        vm.expectEmit(true, true, true, true);
        emit Disinvested(disinvestAmount);

        vault.disinvest(disinvestAmount);
    }

    /// #rebalance ///

    function test_rebalance_FailsIfCallerIsNotKeeper() public {
        _setBalance(address(vault), 1_000_000e6);

        bytes[] memory callData = new bytes[](0);

        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.rebalance(callData);
    }

    function test_rebalance_BorrowOnlyOnAaveV3() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 initialDebt = 100 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance, initialDebt);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, initialDebt);

        _assertCollateralAndDebt(aaveV3.id(), initialBalance, initialDebt);
        _assertCollateralAndDebt(aaveV2.id(), 0, 0);
        _assertCollateralAndDebt(morpho.id(), 0, 0);
    }

    function test_rebalance_WorksIfCallDataContainsAnEmptyItem() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 initialDebt = 100 ether;

        bytes[] memory callData = new bytes[](3);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3.id(), initialBalance);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3.id(), initialDebt);
        callData[2] = ""; // empty bytes

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, initialDebt);

        _assertCollateralAndDebt(aaveV3.id(), initialBalance, initialDebt);
        _assertCollateralAndDebt(aaveV2.id(), 0, 0);
        _assertCollateralAndDebt(morpho.id(), 0, 0);
    }

    function test_rebalance_BorrowOnlyOnMorpho() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 initialDebt = 100 ether;

        vault.addAdapter(morpho);

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, morpho.id(), initialBalance, initialDebt);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, initialDebt);

        _assertCollateralAndDebt(aaveV3.id(), 0, 0);
        _assertCollateralAndDebt(aaveV2.id(), 0, 0);
        _assertCollateralAndDebt(morpho.id(), initialBalance, initialDebt);
    }

    function test_rebalance_BorrowOnMorpho() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 initialDebt = 100 ether;

        // setup morpho
        assertFalse(vault.isSupported(morpho.id()));
        vault.addAdapter(morpho);
        assertTrue(vault.isSupported(morpho.id()));

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, morpho.id(), initialBalance, initialDebt);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, initialDebt);

        _assertCollateralAndDebt(morpho.id(), initialBalance, initialDebt);
    }

    function test_rebalance_BorrowOnlyOnAaveV2() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 initialDebt = 100 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV2.id(), initialBalance, initialDebt);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, initialDebt);

        _assertCollateralAndDebt(aaveV2.id(), initialBalance, initialDebt);
        _assertCollateralAndDebt(aaveV3.id(), 0, 0);
        _assertCollateralAndDebt(morpho.id(), 0, 0);
    }

    function test_rebalance_OneProtocolLeverageDown() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 initialDebt = 100 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV2.id(), initialBalance, initialDebt);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, initialDebt);

        // leverage down
        callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.disinvest.selector, initialDebt / 2);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.repay.selector, aaveV2.id(), initialDebt / 2);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, initialDebt / 2);

        _assertCollateralAndDebt(aaveV2.id(), initialBalance, initialDebt / 2);
    }

    function test_rebalance_OneProtocolLeverageUp() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 initialDebt = 100 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV2.id(), initialBalance, initialDebt);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, initialDebt);

        // leverage up
        callData = new bytes[](1);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV2.id(), initialDebt);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, initialDebt * 2);

        _assertCollateralAndDebt(aaveV2.id(), initialBalance, initialDebt * 2);
    }

    function test_rebalance_OneProtocolWithAdditionalDeposits() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 initialDebt = 100 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance, initialDebt);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, initialDebt);

        uint256 additionalBalance = 100_000e6;
        uint256 additionalDebt = 10 ether;
        deal(address(usdc), address(vault), additionalBalance);

        callData = new bytes[](0);
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), additionalBalance, additionalDebt);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance + additionalBalance, initialDebt + additionalDebt);
    }

    function test_rebalance_TwoProtocols() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 debtOnAaveV3 = 200 ether;
        uint256 debtOnAaveV2 = 200 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance / 2, debtOnAaveV3);
        callData = _getSupplyAndBorrowCallData(callData, aaveV2.id(), initialBalance / 2, debtOnAaveV2);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, debtOnAaveV3 + debtOnAaveV2);

        _assertCollateralAndDebt(aaveV3.id(), initialBalance / 2, debtOnAaveV3);
        _assertCollateralAndDebt(aaveV2.id(), initialBalance / 2, debtOnAaveV2);
    }

    function test_rebalance_AaveV3AndMorpho() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 debtOnAaveV3 = 200 ether;
        uint256 debtOnMorpho = 200 ether;

        // setup morpho
        vault.addAdapter(morpho);
        assertTrue(vault.isSupported(morpho.id()));

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance / 2, debtOnAaveV3);
        callData = _getSupplyAndBorrowCallData(callData, morpho.id(), initialBalance / 2, debtOnMorpho);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, debtOnAaveV3 + debtOnMorpho);

        _assertCollateralAndDebt(aaveV3.id(), initialBalance / 2, debtOnAaveV3);
        _assertCollateralAndDebt(morpho.id(), initialBalance / 2, debtOnMorpho);
    }

    function test_rebalance_TwoProtocolsWithAdditionalDeposits() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 debtOnAaveV3 = 60 ether;
        uint256 debtOnMorpho = 40 ether;

        vault.addAdapter(morpho);

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance / 2, debtOnAaveV3);
        callData = _getSupplyAndBorrowCallData(callData, morpho.id(), initialBalance / 2, debtOnMorpho);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, debtOnAaveV3 + debtOnMorpho);

        uint256 additionalCollateralOnAaveV3 = 50_000e6;
        uint256 additionalCollateralOnMorpho = 100_000e6;
        uint256 additionalDebtOnAaveV3 = 25 ether;
        uint256 additionalDebtOnMorpho = 50 ether;
        deal(address(usdc), address(vault), additionalCollateralOnAaveV3 + additionalCollateralOnMorpho);

        callData = new bytes[](0);
        callData =
            _getSupplyAndBorrowCallData(callData, aaveV3.id(), additionalCollateralOnAaveV3, additionalDebtOnAaveV3);
        callData =
            _getSupplyAndBorrowCallData(callData, morpho.id(), additionalCollateralOnMorpho, additionalDebtOnMorpho);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(
            initialBalance + additionalCollateralOnAaveV3 + additionalCollateralOnMorpho,
            debtOnAaveV3 + debtOnMorpho + additionalDebtOnAaveV3 + additionalDebtOnMorpho
        );

        _assertCollateralAndDebt(
            aaveV3.id(), initialBalance / 2 + additionalCollateralOnAaveV3, debtOnAaveV3 + additionalDebtOnAaveV3
        );
        _assertCollateralAndDebt(
            morpho.id(), initialBalance / 2 + additionalCollateralOnMorpho, debtOnMorpho + additionalDebtOnMorpho
        );
    }

    function test_rebalance_TwoProtocolsLeveragingUpAndDown() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 debtOnAaveV3 = 160 ether;
        uint256 debtOnMorpho = 100 ether;

        vault.addAdapter(morpho);

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance / 2, debtOnAaveV3);
        callData = _getSupplyAndBorrowCallData(callData, morpho.id(), initialBalance / 2, debtOnMorpho);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, debtOnAaveV3 + debtOnMorpho);

        uint256 additionalCollateralOnAaveV3 = 50_000e6;
        uint256 additionalDebtOnAaveV3 = 40 ether; // leverage up
        uint256 debtReductionOnMorpho = 80 ether; // leverage down
        deal(address(usdc), address(vault), additionalCollateralOnAaveV3);

        callData = new bytes[](4);
        callData[0] =
            abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3.id(), additionalCollateralOnAaveV3);
        callData[1] =
            abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3.id(), additionalDebtOnAaveV3);
        callData[2] = abi.encodeWithSelector(
            scCrossAssetYieldVault.disinvest.selector, debtReductionOnMorpho - additionalDebtOnAaveV3
        );
        callData[3] = abi.encodeWithSelector(scCrossAssetYieldVault.repay.selector, morpho.id(), debtReductionOnMorpho);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(
            initialBalance + additionalCollateralOnAaveV3,
            debtOnAaveV3 + debtOnMorpho + additionalDebtOnAaveV3 - debtReductionOnMorpho
        );

        _assertCollateralAndDebt(
            aaveV3.id(), initialBalance / 2 + additionalCollateralOnAaveV3, debtOnAaveV3 + additionalDebtOnAaveV3
        );
        _assertCollateralAndDebt(morpho.id(), initialBalance / 2, debtOnMorpho - debtReductionOnMorpho);
    }

    function test_rebalance_ThreeProtocols() public {
        uint256 initialBalance = _setBalance(address(vault), 1_200_000e6);
        uint256 debtOnAaveV3 = 140 ether;
        uint256 debtOnMorpho = 150 ether;
        uint256 debtOnAaveV2 = 160 ether;

        vault.addAdapter(morpho);

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance / 3, debtOnAaveV3);
        callData = _getSupplyAndBorrowCallData(callData, morpho.id(), initialBalance / 3, debtOnMorpho);
        callData = _getSupplyAndBorrowCallData(callData, aaveV2.id(), initialBalance / 3, debtOnAaveV2);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, debtOnAaveV3 + debtOnMorpho + debtOnAaveV2);

        _assertCollateralAndDebt(aaveV3.id(), initialBalance / 3, debtOnAaveV3);
        _assertCollateralAndDebt(aaveV2.id(), initialBalance / 3, debtOnAaveV2);
        _assertCollateralAndDebt(morpho.id(), initialBalance / 3, debtOnMorpho);
    }

    function test_rebalance_ThreeProtocolsLeveragingDown() public {
        uint256 initialBalance = _setBalance(address(vault), 1_200_000e6);
        uint256 debtOnAaveV3 = 140 ether;
        uint256 debtOnMorpho = 150 ether;
        uint256 debtOnAaveV2 = 160 ether;
        uint256 totalDebt = debtOnAaveV3 + debtOnAaveV2 + debtOnMorpho;

        vault.addAdapter(morpho);

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance / 3, debtOnAaveV3);
        callData = _getSupplyAndBorrowCallData(callData, morpho.id(), initialBalance / 3, debtOnMorpho);
        callData = _getSupplyAndBorrowCallData(callData, aaveV2.id(), initialBalance / 3, debtOnAaveV2);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, totalDebt);

        uint256 debtReductionOnAaveV3 = 40 ether;
        uint256 debtReductionOnMorpho = 50 ether;
        uint256 debtReductionOnAaveV2 = 60 ether;
        uint256 totalDebtReduction = debtReductionOnAaveV3 + debtReductionOnMorpho + debtReductionOnAaveV2;

        callData = new bytes[](4);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.disinvest.selector, totalDebtReduction);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.repay.selector, aaveV3.id(), debtReductionOnAaveV3);
        callData[2] = abi.encodeWithSelector(scCrossAssetYieldVault.repay.selector, morpho.id(), debtReductionOnMorpho);
        callData[3] = abi.encodeWithSelector(scCrossAssetYieldVault.repay.selector, aaveV2.id(), debtReductionOnAaveV2);

        vault.rebalance(callData);

        _assertTotalCollateralAndDebt(initialBalance, totalDebt - totalDebtReduction);

        _assertCollateralAndDebt(aaveV3.id(), initialBalance / 3, debtOnAaveV3 - debtReductionOnAaveV3);
        _assertCollateralAndDebt(aaveV2.id(), initialBalance / 3, debtOnAaveV2 - debtReductionOnAaveV2);
        _assertCollateralAndDebt(morpho.id(), initialBalance / 3, debtOnMorpho - debtReductionOnMorpho);
    }

    function test_rebalance_EmitsRebalancedEvent() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);

        uint256 floatPercentage = 0.01e18;
        vault.setFloatPercentage(floatPercentage);

        uint256 float = initialBalance.mulWadDown(floatPercentage);
        uint256 supplyOnAaveV3 = (initialBalance - float) / 2;
        uint256 supplyOnAaveV2 = (initialBalance - float) / 2;
        uint256 debtOnAaveV3 = 200 ether;
        uint256 debtOnAaveV2 = 200 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), supplyOnAaveV3, debtOnAaveV3);
        callData = _getSupplyAndBorrowCallData(callData, aaveV2.id(), supplyOnAaveV2, debtOnAaveV2);

        vm.expectEmit(true, true, true, true);
        emit Rebalanced(supplyOnAaveV3 + supplyOnAaveV2, debtOnAaveV3 + debtOnAaveV2, float);

        vault.rebalance(callData);
    }

    function test_rebalance_EnforcesFloatAmountToRemainInVault() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);

        uint256 floatPercentage = 0.02e18; // 2%
        vault.setFloatPercentage(floatPercentage);
        assertEq(vault.floatPercentage(), floatPercentage, "floatPercentage");

        uint256 expectedFloat = initialBalance.mulWadUp(floatPercentage);
        uint256 actualFloat = 1_000e6; // this much is left in the vault

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance - actualFloat, 50 ether);

        vm.expectRevert(abi.encodeWithSelector(FloatBalanceTooLow.selector, actualFloat, expectedFloat));
        vault.rebalance(callData);
    }

    function test_rebalance_canBeUsedToSellProfitsAndReinvest() public {
        uint256 targetLtv = 0.7e18;
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 initialDebt = priceConverter.assetToTargetToken(initialBalance.mulWadDown(targetLtv));

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV2.id(), initialBalance, initialDebt);

        vault.rebalance(callData);

        // add 10% profit to the weth vault
        uint256 totalBefore = vault.totalAssets();
        uint256 wethProfit = vault.targetTokenInvestedAmount().mulWadUp(0.1e18);
        uint256 usdcProfit = priceConverter.targetTokenToAsset(wethProfit);
        deal(address(weth), address(wethVault), vault.targetTokenInvestedAmount() + wethProfit);

        assertApproxEqRel(vault.totalAssets(), totalBefore + usdcProfit, 0.01e18, "total assets before reinvest");

        uint256 minUsdcAmountOut = usdcProfit.mulWadDown(vault.slippageTolerance());
        uint256 wethToReinvest = priceConverter.assetToTargetToken(minUsdcAmountOut);
        callData = new bytes[](3);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.sellProfit.selector, minUsdcAmountOut);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV2.id(), minUsdcAmountOut);
        callData[2] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV2.id(), wethToReinvest);

        vault.rebalance(callData);

        assertApproxEqRel(vault.totalAssets(), totalBefore + usdcProfit, 0.01e18, "total assets after reinvest");
        assertApproxEqAbs(vault.getCollateral(aaveV2.id()), initialBalance + minUsdcAmountOut, 1, "collateral");
        assertTrue(vault.getDebt(aaveV2.id()) > initialDebt + wethToReinvest, "debt");
        assertApproxEqAbs(
            vault.getDebt(aaveV2.id()), vault.targetTokenInvestedAmount(), 1, "debt and weth invested mismatch"
        );
    }

    function testFuzz_rebalance(
        uint256 supplyOnAaveV3,
        uint256 borrowOnAaveV3,
        uint256 supplyOnAaveV2,
        uint256 borrowOnAaveV2
    ) public {
        uint256 floatPercentage = 0.01e18;
        vault.setFloatPercentage(floatPercentage);

        supplyOnAaveV3 = bound(supplyOnAaveV3, 1e6, 10_000_000e6);
        supplyOnAaveV2 = bound(supplyOnAaveV2, 1e6, 10_000_000e6);

        uint256 initialBalance =
            _setBalance(address(vault), (supplyOnAaveV3 + supplyOnAaveV2).divWadDown(1e18 - floatPercentage));
        uint256 minFloat = (supplyOnAaveV3 + supplyOnAaveV2).mulWadDown(floatPercentage);

        borrowOnAaveV3 = bound(
            borrowOnAaveV3,
            1,
            priceConverter.assetToTargetToken(supplyOnAaveV3).mulWadDown(aaveV3.getMaxLtv() - 0.005e18) // -0.5% to avoid borrowing at max ltv
        );
        borrowOnAaveV2 = bound(
            borrowOnAaveV2,
            1,
            priceConverter.assetToTargetToken(supplyOnAaveV2).mulWadDown(aaveV2.getMaxLtv() - 0.005e18)
        );

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), supplyOnAaveV3, borrowOnAaveV3);
        callData = _getSupplyAndBorrowCallData(callData, aaveV2.id(), supplyOnAaveV2, borrowOnAaveV2);

        vault.rebalance(callData);

        _assertCollateralAndDebt(aaveV3.id(), supplyOnAaveV3, borrowOnAaveV3);
        _assertCollateralAndDebt(aaveV2.id(), supplyOnAaveV2, borrowOnAaveV2);
        assertApproxEqAbs(vault.totalAssets(), initialBalance, 2, "total asets");
        assertApproxEqAbs(_usdcBalance(), minFloat, vault.totalAssets().mulWadDown(floatPercentage), "float");
    }

    /// #reallocate ///

    function test_reallocate_FailsIfCallerIsNotKeeper() public {
        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.reallocate(0, new bytes[](0));
    }

    function test_reallocate_FailsIfFlashLoanParameterIsZero() public {
        vm.expectRevert(FlashLoanAmountZero.selector);
        vault.reallocate(0, new bytes[](0));
    }

    function test_reallocate_MoveEverythingFromOneProtocolToAnother() public {
        vault.addAdapter(morpho);

        uint256 totalCollateral = _setBalance(address(vault), 1_000_000e6);
        uint256 totalDebt = 100 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), totalCollateral, totalDebt);

        vault.rebalance(callData);

        _assertCollateralAndDebt(aaveV3.id(), totalCollateral, totalDebt);
        _assertCollateralAndDebt(aaveV2.id(), 0, 0);
        _assertCollateralAndDebt(morpho.id(), 0, 0);

        // move everything from Aave to Morpho
        uint256 collateralToMove = totalCollateral;
        uint256 debtToMove = totalDebt;
        uint256 flashLoanAmount = debtToMove;

        callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.repay.selector, aaveV3.id(), debtToMove);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.withdraw.selector, aaveV3.id(), collateralToMove);
        callData = _getSupplyAndBorrowCallData(callData, morpho.id(), collateralToMove, debtToMove);

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        vault.reallocate(flashLoanAmount, callData);

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        _assertTotalCollateralAndDebt(totalCollateral, totalDebt);

        _assertCollateralAndDebt(aaveV3.id(), 0, 0);
        _assertCollateralAndDebt(aaveV2.id(), 0, 0);
        _assertCollateralAndDebt(morpho.id(), totalCollateral, totalDebt);
    }

    function test_reallocate_FailsIfThereIsNoDownsizeOnAtLeastOnProtocol() public {
        vault.addAdapter(morpho);

        uint256 totalCollateral = _setBalance(address(vault), 1_000_000e6);
        uint256 totalDebt = 100 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), totalCollateral, totalDebt);

        vault.rebalance(callData);

        _assertCollateralAndDebt(aaveV3.id(), totalCollateral, totalDebt);
        _assertCollateralAndDebt(aaveV2.id(), 0, 0);
        _assertCollateralAndDebt(morpho.id(), 0, 0);

        // move everything from Aave to morpho
        uint256 collateralToMove = totalCollateral / 2;
        uint256 debtToMove = totalDebt / 2;
        uint256 flashLoanAmount = debtToMove;

        callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, morpho.id(), collateralToMove);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, morpho.id(), debtToMove);

        vm.expectRevert();
        vault.reallocate(flashLoanAmount, callData);
    }

    function test_reallocate_MoveHalfFromOneProtocolToAnother() public {
        vault.addAdapter(morpho);

        uint256 totalCollateral = _setBalance(address(vault), 1_000_000e6);
        uint256 totalDebt = 100 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), totalCollateral / 2, totalDebt / 2);
        callData = _getSupplyAndBorrowCallData(callData, morpho.id(), totalCollateral / 2, totalDebt / 2);

        vault.rebalance(callData);

        _assertCollateralAndDebt(aaveV3.id(), totalCollateral / 2, totalDebt / 2);
        _assertCollateralAndDebt(aaveV2.id(), 0, 0);
        _assertCollateralAndDebt(morpho.id(), totalCollateral / 2, totalDebt / 2);

        // move half of the position from Aave to Euler
        uint256 collateralToMove = totalCollateral / 4;
        uint256 debtToMove = totalDebt / 4;
        uint256 flashLoanAmount = 100 ether;

        callData = new bytes[](4);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.repay.selector, aaveV3.id(), debtToMove);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.withdraw.selector, aaveV3.id(), collateralToMove);
        callData[2] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, morpho.id(), collateralToMove);
        callData[3] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, morpho.id(), debtToMove);

        vault.reallocate(flashLoanAmount, callData);

        _assertTotalCollateralAndDebt(totalCollateral, totalDebt);

        _assertCollateralAndDebt(aaveV3.id(), totalCollateral / 4, totalDebt / 4);
        _assertCollateralAndDebt(aaveV2.id(), 0, 0);
        _assertCollateralAndDebt(morpho.id(), totalCollateral * 3 / 4, totalDebt * 3 / 4);
    }

    function test_reallocate_MovesDebtFromOneToMultipleOtherProtocols() public {
        vault.addAdapter(morpho);

        uint256 totalCollateral = _setBalance(address(vault), 1_000_000e6);
        uint256 totalDebt = 100 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), totalCollateral, totalDebt);

        vault.rebalance(callData);

        // move half from Aave v3 to Morpho and Aave v2 equally
        uint256 collateralToMoveFromAaveV3 = totalCollateral / 2;
        uint256 collateralToMoveToAaveV2 = collateralToMoveFromAaveV3 / 2;
        uint256 collateralToMoveToMorpho = collateralToMoveFromAaveV3 / 2;
        uint256 debtToMoveFromAaveV3 = totalDebt / 2;
        uint256 debtToMoveToAaveV2 = debtToMoveFromAaveV3 / 2;
        uint256 debtToMoveToMorpho = debtToMoveFromAaveV3 / 2;
        uint256 flashLoanAmount = debtToMoveFromAaveV3;

        callData = new bytes[](6);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.repay.selector, aaveV3.id(), debtToMoveFromAaveV3);
        callData[1] =
            abi.encodeWithSelector(scCrossAssetYieldVault.withdraw.selector, aaveV3.id(), collateralToMoveFromAaveV3);
        callData[2] =
            abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, morpho.id(), collateralToMoveToMorpho);
        callData[3] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, morpho.id(), debtToMoveToMorpho);
        callData[4] =
            abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV2.id(), collateralToMoveToAaveV2);
        callData[5] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV2.id(), debtToMoveToAaveV2);

        vault.reallocate(flashLoanAmount, callData);

        _assertCollateralAndDebt(
            aaveV3.id(), totalCollateral - collateralToMoveFromAaveV3, totalDebt - debtToMoveFromAaveV3
        );
        _assertCollateralAndDebt(aaveV2.id(), collateralToMoveToAaveV2, debtToMoveToAaveV2);
        _assertCollateralAndDebt(morpho.id(), collateralToMoveToMorpho, debtToMoveToMorpho);
    }

    function test_reallocate_WorksWhenCalledMultipleTimes() public {
        vault.addAdapter(morpho);

        uint256 totalCollateral = _setBalance(address(vault), 1_000_000e6);
        uint256 totalDebt = 100 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), totalCollateral / 2, totalDebt / 2);
        callData = _getSupplyAndBorrowCallData(callData, morpho.id(), totalCollateral / 2, totalDebt / 2);

        vault.rebalance(callData);

        // 1. move half of the position from Aave to Morpho
        uint256 collateralToMove = vault.totalCollateral() / 2;
        uint256 debtToMove = totalDebt / 2;
        uint256 flashLoanAmount = debtToMove;

        callData = new bytes[](4);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.repay.selector, aaveV3.id(), debtToMove);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.withdraw.selector, aaveV3.id(), collateralToMove);
        callData[2] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, morpho.id(), collateralToMove);
        callData[3] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, morpho.id(), debtToMove);

        vault.reallocate(flashLoanAmount, callData);

        // 2. move everyting to Aave
        collateralToMove = morpho.getCollateral(address(vault));
        debtToMove = morpho.getDebt(address(vault));

        callData = new bytes[](4);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.repay.selector, morpho.id(), debtToMove);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.withdraw.selector, morpho.id(), collateralToMove);
        callData[2] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3.id(), collateralToMove);
        callData[3] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, aaveV3.id(), debtToMove);

        flashLoanAmount = debtToMove;
        vault.reallocate(flashLoanAmount, callData);

        _assertTotalCollateralAndDebt(totalCollateral, totalDebt);

        _assertCollateralAndDebt(aaveV3.id(), totalCollateral, totalDebt);
        _assertCollateralAndDebt(morpho.id(), 0, 0);
    }

    function test_reallocate_EmitsReallocatedEvent() public {
        vault.addAdapter(morpho);

        uint256 totalCollateral = _setBalance(address(vault), 1_000_000e6);

        bytes[] memory callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3.id(), totalCollateral / 2);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, morpho.id(), totalCollateral / 2);

        vault.rebalance(callData);

        // 1. move half of the position from Aave to Euler
        uint256 collateralToMove = totalCollateral / 4;

        callData = new bytes[](2);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.withdraw.selector, aaveV3.id(), collateralToMove);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, morpho.id(), collateralToMove);

        vm.expectEmit(true, true, true, true);
        emit Reallocated();

        vault.reallocate(1, callData);
    }

    function test_reallocate_PaysFlashLoanFees() public {
        vault.addAdapter(morpho);

        uint256 totalCollateral = _setBalance(address(vault), 1_000_000e6);
        uint256 totalDebt = 100 ether;

        IProtocolFeesCollector balancerFeeContract = IProtocolFeesCollector(C.BALANCER_FEES_COLLECTOR);

        uint256 flashLoanFeePercent = 0.01e18;
        vm.prank(C.BALANCER_ADMIN);
        balancerFeeContract.setFlashLoanFeePercentage(flashLoanFeePercent);
        assertEq(balancerFeeContract.getFlashLoanFeePercentage(), flashLoanFeePercent);

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), totalCollateral, totalDebt);

        vault.rebalance(callData);

        // 1. move half of the position from Aave to Euler
        uint256 collateralToMove = aaveV3.getCollateral(address(vault)) / 2;
        uint256 debtToMove = aaveV3.getDebt(address(vault)) / 2;
        uint256 flashLoanFee = debtToMove.mulWadUp(0.01e18);
        uint256 flashLoanAmount = debtToMove;

        callData = new bytes[](4);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.repay.selector, aaveV3.id(), debtToMove);
        callData[1] = abi.encodeWithSelector(scCrossAssetYieldVault.withdraw.selector, aaveV3.id(), collateralToMove);
        callData[2] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, morpho.id(), collateralToMove);
        callData[3] = abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, morpho.id(), debtToMove);

        // expect to fail since flash loan fees are not accounted for
        vm.expectRevert();
        vault.reallocate(flashLoanAmount, callData);

        // borrow more to cover the flash loan fees
        callData[3] =
            abi.encodeWithSelector(scCrossAssetYieldVault.borrow.selector, morpho.id(), debtToMove + flashLoanFee);
        vault.reallocate(flashLoanAmount, callData);
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
        IVault balancer = IVault(C.BALANCER_VAULT);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);

        tokens[0] = address(weth);
        amounts[0] = 100e18;

        vm.prank(address(balancer));
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
        vault.addAdapter(morpho);

        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 initialDebt = 100 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance / 2, initialDebt / 2);
        callData = _getSupplyAndBorrowCallData(callData, morpho.id(), initialBalance / 2, initialDebt / 2);

        vault.rebalance(callData);

        // add 100% profit to the weth vault
        uint256 initialWethInvested = vault.targetTokenInvestedAmount();
        deal(address(weth), address(wethVault), initialWethInvested * 2);

        uint256 usdcBalanceBefore = _usdcBalance();
        uint256 profit = vault.getProfit();

        vm.prank(keeper);
        vault.sellProfit(0);

        uint256 expectedUsdcBalance = usdcBalanceBefore + priceConverter.targetTokenToAsset(profit);
        _assertCollateralAndDebt(aaveV3.id(), initialBalance / 2, initialDebt / 2);
        _assertCollateralAndDebt(morpho.id(), initialBalance / 2, initialDebt / 2);
        assertApproxEqRel(_usdcBalance(), expectedUsdcBalance, 0.01e18, "usdc balance");
        assertApproxEqRel(
            vault.targetTokenInvestedAmount(), initialWethInvested, 0.001e18, "sold more than actual profit"
        );
    }

    function test_sellProfit_EmitsEvent() public {
        vault.addAdapter(morpho);

        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 initialDebt = 100 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance / 2, initialDebt / 2);
        callData = _getSupplyAndBorrowCallData(callData, morpho.id(), initialBalance / 2, initialDebt / 2);

        vault.rebalance(callData);

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested * 2);
        uint256 profit = vault.targetTokenInvestedAmount() - vault.totalDebt();

        vm.expectEmit(true, true, true, true);
        emit ProfitSold(profit, 184856_904862);
        vm.prank(keeper);
        vault.sellProfit(0);
    }

    function test_sellProfit_FailsIfAmountReceivedIsLeessThanAmountOutMin() public {
        vault.addAdapter(morpho);

        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);
        uint256 initialDebt = 200 ether;

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance / 2, initialDebt / 2);
        callData = _getSupplyAndBorrowCallData(callData, morpho.id(), initialBalance / 2, initialDebt / 2);

        vault.rebalance(callData);

        // add 100% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested * 2);

        uint256 tooLargeUsdcAmountOutMin = priceConverter.targetTokenToAsset(vault.getProfit()).mulWadDown(1.05e18); // add 5% more than expected

        vm.prank(keeper);
        vm.expectRevert("Too little received");
        vault.sellProfit(tooLargeUsdcAmountOutMin);
    }

    /// #withdraw ///

    function test_withdraw_WorksWithOneProtocol() public {
        uint256 initialBalance = _setBalance(address(alice), 1_000_000e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), initialBalance);
        vault.deposit(initialBalance, alice);
        vm.stopPrank();

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance, 200 ether);

        vault.rebalance(callData);

        uint256 withdrawAmount = vault.convertToAssets(vault.balanceOf(alice));
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(usdc.balanceOf(alice), withdrawAmount, "alice usdc balance");
    }

    function test_withdraw_PullsFundsFromFloatFirst() public {
        uint256 floatPercentage = 0.1e18; // 10 %
        vault.setFloatPercentage(floatPercentage);
        uint256 initialBalance = _setBalance(address(alice), 1_000_000e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), initialBalance);
        vault.deposit(initialBalance, alice);
        vm.stopPrank();

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(
            callData, aaveV3.id(), initialBalance.mulWadDown(1e18 - floatPercentage), 200 ether
        );

        vault.rebalance(callData);

        uint256 collateralBefore = vault.getCollateral(aaveV3.id());
        uint256 debtBefore = vault.getDebt(aaveV3.id());

        uint256 withdrawAmount = usdc.balanceOf(address(vault));
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(usdc.balanceOf(alice), withdrawAmount, "alice usdc balance");
        _assertTotalCollateralAndDebt(collateralBefore, debtBefore);
    }

    function test_withdraw_PullsFundsFromSellingProfitSecond() public {
        uint256 floatPercentage = 0.1e18; // 10 %
        vault.setFloatPercentage(floatPercentage);
        uint256 initialBalance = _setBalance(address(alice), 1_000_000e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), initialBalance);
        vault.deposit(initialBalance, alice);
        vm.stopPrank();

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(
            callData, aaveV3.id(), initialBalance.mulWadDown(1e18 - floatPercentage), 200 ether
        );

        vault.rebalance(callData);

        // add 100% profit to the weth vault
        uint256 initialWethInvested = vault.targetTokenInvestedAmount();
        deal(address(weth), address(wethVault), initialWethInvested * 2);

        uint256 collateralBefore = vault.totalCollateral();
        uint256 debtBefore = vault.totalDebt();

        uint256 profit = vault.getProfit();
        uint256 expectedUsdcFromProfitSelling = priceConverter.targetTokenToAsset(profit);
        uint256 initialFloat = _usdcBalance();
        // withdraw double the float amount
        uint256 withdrawAmount = initialFloat * 2;
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(usdc.balanceOf(alice), withdrawAmount, "alice usdc balance");
        assertApproxEqAbs(vault.getProfit(), 0, 1, "profit not sold");
        assertApproxEqRel(_usdcBalance(), expectedUsdcFromProfitSelling - initialFloat, 0.01e18, "float remaining");
        _assertTotalCollateralAndDebt(collateralBefore, debtBefore);
    }

    function test_withdraw_PullsFundsFromInvestedWhenFloatAndProfitSellingIsNotEnough() public {
        uint256 floatPercentage = 0.1e18; // 10 %
        vault.setFloatPercentage(floatPercentage);
        uint256 initialBalance = _setBalance(address(alice), 1_000_000e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), initialBalance);
        vault.deposit(initialBalance, alice);
        vm.stopPrank();

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(
            callData, aaveV3.id(), initialBalance.mulWadDown(1e18 - floatPercentage), 200 ether
        );

        vault.rebalance(callData);

        // add 50% profit to the weth vault
        uint256 initialWethInvested = vault.targetTokenInvestedAmount();
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
        uint256 initialBalance = _setBalance(address(alice), 1_000_000e6);
        uint256 initialDebt = 100 ether;

        vm.startPrank(alice);
        usdc.approve(address(vault), initialBalance);
        vault.deposit(initialBalance, alice);
        vm.stopPrank();

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance / 2, initialDebt / 2);
        callData = _getSupplyAndBorrowCallData(callData, aaveV2.id(), initialBalance / 2, initialDebt / 2);

        vault.rebalance(callData);

        uint256 withdrawAmount = initialBalance / 2;
        uint256 endCollateral = initialBalance / 2;
        uint256 endDebt = initialDebt / 2;
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertApproxEqRel(usdc.balanceOf(alice), withdrawAmount, 0.01e18, "alice usdc balance");

        _assertTotalCollateralAndDebt(endCollateral, endDebt);

        uint256 collateralOnAaveV3 = aaveV3.getCollateral(address(vault));
        uint256 debtOnAaveV3 = aaveV3.getDebt(address(vault));
        uint256 collateralOnAaveV2 = aaveV2.getCollateral(address(vault));
        uint256 debtOnAaveV2 = aaveV2.getDebt(address(vault));

        assertApproxEqRel(collateralOnAaveV3, endCollateral / 2, 0.01e18, "collateral on aave v3");
        assertApproxEqRel(collateralOnAaveV2, endCollateral / 2, 0.01e18, "collateral on euler");
        assertApproxEqRel(debtOnAaveV3, endDebt / 2, 0.01e18, "debt on aave v3");
        assertApproxEqRel(debtOnAaveV2, endDebt / 2, 0.01e18, "debt on euler");
    }

    function test_withdraw_worksIfThereIsNoDebtPositionOnOneOfTheProtocols() public {
        uint256 initialBalance = _setBalance(address(alice), 1_000_000e6);

        vm.startPrank(alice);
        usdc.approve(address(vault), initialBalance);
        vault.deposit(initialBalance, alice);
        vm.stopPrank();

        bytes[] memory callData = new bytes[](1);
        callData[0] = abi.encodeWithSelector(scCrossAssetYieldVault.supply.selector, aaveV3.id(), initialBalance / 2);
        callData = _getSupplyAndBorrowCallData(callData, aaveV2.id(), initialBalance / 2, 100 ether);

        vault.rebalance(callData);

        uint256 withdrawAmount = vault.convertToAssets(vault.balanceOf(alice));
        vm.prank(alice);
        vault.withdraw(withdrawAmount, alice, alice);

        assertEq(usdc.balanceOf(alice), withdrawAmount, "alice usdc balance");
    }

    function testFuzz_withdraw(uint256 _amount, uint256 _withdrawAmount) public {
        _amount = bound(_amount, 1e6, 5_000_000e6); // upper limit constrained by weth available on aave v3 at the fork block number
        _setBalance(alice, _amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(_amount, alice);
        vm.stopPrank();

        uint256 borrowAmount = priceConverter.assetToTargetToken(_amount.mulWadDown(0.5e18));

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), _amount, borrowAmount);

        vault.rebalance(callData);

        uint256 total = vault.totalAssets();
        _withdrawAmount = bound(_withdrawAmount, 1e6, total);
        vm.startPrank(alice);
        vault.withdraw(_withdrawAmount, alice, alice);

        assertApproxEqAbs(vault.totalAssets(), total - _withdrawAmount, 1, "total assets");
        assertApproxEqAbs(usdc.balanceOf(alice), _withdrawAmount, 0.01e6, "usdc balance");
    }

    function testFuzz_withdraw_whenInProfit(uint256 _amount, uint256 _withdrawAmount) public {
        _amount = bound(_amount, 1e6, 10_000_000e6); // upper limit constrained by weth available on aave v3
        _setBalance(alice, _amount);

        vm.startPrank(alice);
        usdc.approve(address(vault), type(uint256).max);
        vault.deposit(_amount, alice);
        vm.stopPrank();

        uint256 borrowAmount = priceConverter.assetToTargetToken(_amount.mulWadDown(0.7e18));

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(
            callData, aaveV3.id(), _amount.mulWadDown(0.3e18), borrowAmount.mulWadDown(0.3e18)
        );
        callData = _getSupplyAndBorrowCallData(
            callData, aaveV2.id(), _amount.mulWadDown(0.7e18), borrowAmount.mulWadDown(0.7e18)
        );

        vault.rebalance(callData);

        // add 1% profit to the weth vault
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested.mulWadUp(1.01e18));

        uint256 total = vault.totalAssets();
        _withdrawAmount = bound(_withdrawAmount, 1e6, total);
        vm.startPrank(alice);
        vault.withdraw(_withdrawAmount, alice, alice);

        assertApproxEqAbs(vault.totalAssets(), total - _withdrawAmount, total.mulWadDown(0.001e18), "total assets");
        assertApproxEqAbs(usdc.balanceOf(alice), _withdrawAmount, _amount.mulWadDown(0.001e18), "usdc balance");
    }

    /// #exitAllPositions ///

    function test_exitAllPositions_FailsIfCallerNotKeeper() public {
        vm.prank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.exitAllPositions(0);
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralOnOneProtocolAndNoProfit() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance, 200 ether);

        vault.rebalance(callData);

        assertEq(vault.getProfit(), 0, "profit");

        uint256 totalBefore = vault.totalAssets();

        vault.exitAllPositions(0);

        assertApproxEqRel(_usdcBalance(), totalBefore, 0.001e18, "vault usdc balance");
        assertEq(weth.balanceOf(address(vault)), 0, "weth balance");
        assertEq(vault.targetTokenInvestedAmount(), 0, "weth invested");
        _assertTotalCollateralAndDebt(0, 0);
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralOnOneProtocolWhenUnderwater() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance, 200 ether);

        vault.rebalance(callData);

        // simulate 50% loss
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested / 2);

        uint256 totalBefore = vault.totalAssets();

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        vault.exitAllPositions(0);

        assertFalse(vault.flashLoanInitiated(), "flash loan initiated");

        assertApproxEqRel(_usdcBalance(), totalBefore, 0.01e18, "vault usdc balance");
        assertEq(weth.balanceOf(address(vault)), 0, "weth balance");
        assertEq(vault.targetTokenInvestedAmount(), 0, "weth invested");
        _assertTotalCollateralAndDebt(0, 0);
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralOnOneProtocolWhenInProfit() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialBalance, 200 ether);

        vault.rebalance(callData);

        // simulate 50% profit
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested.mulWadUp(1.5e18));

        assertEq(vault.getProfit(), 100 ether, "profit");

        uint256 totalBefore = vault.totalAssets();

        vault.exitAllPositions(0);

        assertApproxEqRel(_usdcBalance(), totalBefore, 0.005e18, "vault usdc balance");
        assertEq(weth.balanceOf(address(vault)), 0, "weth balance");
        assertEq(vault.targetTokenInvestedAmount(), 0, "weth invested");
        _assertTotalCollateralAndDebt(0, 0);
    }

    function test_exitAllPositions_RepaysDebtAndReleasesCollateralOnAllProtocols() public {
        uint256 initialCollateralPerProtocol = 500_000e6;
        uint256 initialDebtPerProtocol = 100 ether;
        _setBalance(address(vault), initialCollateralPerProtocol * 3);

        vault.addAdapter(morpho);

        bytes[] memory callData;
        callData =
            _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialCollateralPerProtocol, initialDebtPerProtocol);
        callData =
            _getSupplyAndBorrowCallData(callData, aaveV2.id(), initialCollateralPerProtocol, initialDebtPerProtocol);
        callData =
            _getSupplyAndBorrowCallData(callData, morpho.id(), initialCollateralPerProtocol, initialDebtPerProtocol);

        vault.rebalance(callData);

        // simulate 50% loss
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested / 2);

        uint256 totalBefore = vault.totalAssets();

        vault.exitAllPositions(0);

        assertApproxEqRel(_usdcBalance(), totalBefore, 0.01e18, "vault usdc balance");
        _assertTotalCollateralAndDebt(0, 0);
    }

    function test_exitAllPositions_EmitsEventOnSuccess() public {
        uint256 initialCollateralPerProtocol = 500_000e6;
        uint256 initialDebtPerProtocol = 100 ether;
        _setBalance(address(vault), initialCollateralPerProtocol * 3);

        vault.addAdapter(morpho);

        bytes[] memory callData;
        callData =
            _getSupplyAndBorrowCallData(callData, aaveV3.id(), initialCollateralPerProtocol, initialDebtPerProtocol);
        callData =
            _getSupplyAndBorrowCallData(callData, aaveV2.id(), initialCollateralPerProtocol, initialDebtPerProtocol);
        callData =
            _getSupplyAndBorrowCallData(callData, morpho.id(), initialCollateralPerProtocol, initialDebtPerProtocol);

        vault.rebalance(callData);

        uint256 invested = vault.targetTokenInvestedAmount();
        uint256 debt = vault.totalDebt();
        uint256 collateral = vault.totalCollateral();

        vm.expectEmit(true, true, true, true);
        emit EmergencyExitExecuted(address(this), invested, debt, collateral);
        vault.exitAllPositions(0);
    }

    function test_exitAllPositions_FailsIfEndBalanceIsLowerThanMinWhenUnderwater() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV2.id(), initialBalance, 200 ether);

        vault.rebalance(callData);

        // simulate 50% loss
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested / 2);

        uint256 invalidEndUsdcBalanceMin = vault.totalAssets().mulWadDown(1.05e18);

        vm.expectRevert(EndAssetBalanceTooLow.selector);
        vault.exitAllPositions(invalidEndUsdcBalanceMin);
    }

    function test_exitAllPositions_FailsIfEndBalanceIsLowerThanMinWhenInProfit() public {
        uint256 initialBalance = _setBalance(address(vault), 1_000_000e6);

        bytes[] memory callData;
        callData = _getSupplyAndBorrowCallData(callData, aaveV2.id(), initialBalance, 200 ether);

        vault.rebalance(callData);

        // simulate 50% profit on invested weth
        uint256 wethInvested = weth.balanceOf(address(wethVault));
        deal(address(weth), address(wethVault), wethInvested.mulWadUp(1.5e18));

        uint256 invalidEndUsdcBalanceMin = vault.totalAssets().mulWadDown(1.05e18);

        vm.expectRevert(EndAssetBalanceTooLow.selector);
        vault.exitAllPositions(invalidEndUsdcBalanceMin);
    }

    /// #swapTokens ///

    function test_swapTokens_FailsIfCallerIsNotKeeper() public {
        _setUpForkAtBlock(EUL_SWAP_BLOCK);
        vm.startPrank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.swapTokens(C.EULER_REWARDS_TOKEN, C.USDC, 1, 0, bytes("0"));
    }

    function test_swapTokens_SwapsEulerForUsdc() public {
        _setUpForkAtBlock(EUL_SWAP_BLOCK);

        uint256 initialUsdcBalance = 2_000e6;
        deal(address(usdc), address(vault), initialUsdcBalance);
        deal(C.EULER_REWARDS_TOKEN, address(vault), EUL_AMOUNT * 2);

        assertEq(ERC20(C.EULER_REWARDS_TOKEN).balanceOf(address(vault)), EUL_AMOUNT * 2, "euler initial balance");
        assertEq(_usdcBalance(), initialUsdcBalance, "usdc balance");
        assertEq(vault.totalAssets(), initialUsdcBalance, "total assets");

        vault.swapTokens(C.EULER_REWARDS_TOKEN, C.USDC, EUL_AMOUNT, EUL_SWAP_USDC_RECEIVED, EUL_SWAP_DATA);

        assertEq(ERC20(C.EULER_REWARDS_TOKEN).balanceOf(address(vault)), EUL_AMOUNT, "euler end balance");
        assertEq(vault.totalAssets(), initialUsdcBalance + EUL_SWAP_USDC_RECEIVED, "vault total assets");
        assertEq(_usdcBalance(), initialUsdcBalance + EUL_SWAP_USDC_RECEIVED, "vault usdc balance");
        assertEq(ERC20(C.EULER_REWARDS_TOKEN).allowance(address(vault), C.ZERO_EX_ROUTER), 0, "0x token allowance");
    }

    function test_swapTokens_EmitsEventOnSuccessfulSwap() public {
        _setUpForkAtBlock(EUL_SWAP_BLOCK);

        deal(C.EULER_REWARDS_TOKEN, address(vault), EUL_AMOUNT);

        vm.expectEmit(true, true, true, true);
        emit TokenSwapped(C.EULER_REWARDS_TOKEN, C.USDC, EUL_AMOUNT, EUL_SWAP_USDC_RECEIVED);

        vault.swapTokens(C.EULER_REWARDS_TOKEN, C.USDC, EUL_AMOUNT, 0, EUL_SWAP_DATA);
    }

    function test_swapTokens_FailsIfUsdcAmountReceivedIsLessThanMin() public {
        _setUpForkAtBlock(EUL_SWAP_BLOCK);

        deal(C.EULER_REWARDS_TOKEN, address(vault), EUL_AMOUNT);

        vm.expectRevert(AmountReceivedBelowMin.selector);
        vault.swapTokens(C.EULER_REWARDS_TOKEN, C.USDC, EUL_AMOUNT, EUL_SWAP_USDC_RECEIVED + 1, EUL_SWAP_DATA);
    }

    function test_swapTokens_FailsIfSwapIsNotSucessful() public {
        _setUpForkAtBlock(EUL_SWAP_BLOCK);

        deal(C.EULER_REWARDS_TOKEN, address(vault), EUL_AMOUNT);

        bytes memory invalidSwapData = hex"6af479b20000";

        vm.expectRevert(Errors.FailedCall.selector);
        vault.swapTokens(C.EULER_REWARDS_TOKEN, C.USDC, EUL_AMOUNT, 0, invalidSwapData);
    }

    /// #claimRewards ///

    function test_claimRewards_FailsIfCallerIsNotKeeper() public {
        vm.startPrank(alice);
        vm.expectRevert(CallerNotKeeper.selector);
        vault.claimRewards(0, "");
    }

    function test_claimRewards_UsesDelegateCallAndEmitsEvent() public {
        IAdapter adapter = new FaultyAdapter();
        vault.addAdapter(adapter);
        uint256 id = adapter.id();

        vm.expectEmit(true, true, true, true);
        emit RewardsClaimed(id);

        vault.claimRewards(id, abi.encode(address(vault)));
    }

    /// #setSlippageTolerance ///

    function test_setSlippageTolerance_FailsIfCallerIsNotAdmin() public {
        uint256 tolerance = 0.01e18;

        vm.startPrank(alice);
        vm.expectRevert(CallerNotAdmin.selector);
        vault.setSlippageTolerance(tolerance);
    }

    function test_setSlippageTolerance_FailsIfSlippageToleranceGreaterThanOne() public {
        uint256 tolerance = 1e18 + 1;

        vm.expectRevert(InvalidSlippageTolerance.selector);
        vault.setSlippageTolerance(tolerance);
    }

    function test_setSlippageTolearnce_UpdatesSlippageTolerance() public {
        uint256 newTolerance = 0.01e18;

        vm.expectEmit(true, true, true, true);
        emit SlippageToleranceUpdated(address(this), newTolerance);

        vault.setSlippageTolerance(newTolerance);

        assertEq(vault.slippageTolerance(), newTolerance, "slippage tolerance");
    }

    /// internal helper functions ///

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
        priceConverter = new UsdcWethPriceConverter();
        swapper = new UsdcWethSwapperHarness();

        vault = new scUSDCv2(address(this), keeper, wethVault, priceConverter, swapper);

        vault.addAdapter(aaveV3);
        vault.addAdapter(aaveV2);

        // set vault eth balance to zero
        vm.deal(address(vault), 0);
        // set float percentage to 0 for most tests
        vault.setFloatPercentage(0);
        // assign keeper role to deployer
        vault.grantRole(vault.KEEPER_ROLE(), address(this));
    }

    function _setBalance(address _account, uint256 _amount) internal returns (uint256) {
        deal(address(usdc), _account, _amount);
        return _amount;
    }

    function _assertCollateralAndDebt(uint256 _protocolId, uint256 _expectedCollateral, uint256 _expectedDebt)
        internal
    {
        uint256 collateral = vault.getCollateral(_protocolId);
        uint256 debt = vault.getDebt(_protocolId);
        string memory protocolName = _protocolIdToString(_protocolId);

        assertApproxEqAbs(collateral, _expectedCollateral, 2, string(abi.encodePacked("collateral on ", protocolName)));
        assertApproxEqAbs(debt, _expectedDebt, 2, string(abi.encodePacked("debt on ", protocolName)));
    }

    function _assertTotalCollateralAndDebt(uint256 _expectedCollateral, uint256 _expectedDebt) internal {
        uint256 totalCollateral = vault.totalCollateral();
        uint256 totalDebt = vault.totalDebt();

        // account for precision loss
        assertApproxEqAbs(totalCollateral, _expectedCollateral, 2, "total collateral");
        assertApproxEqAbs(totalDebt, _expectedDebt, 2, "total debt");
    }

    function _getSupplyAndBorrowCallData(
        bytes[] memory _callData,
        uint256 _protocolId,
        uint256 _supplyAmount,
        uint256 _borrowAmount
    ) internal pure returns (bytes[] memory returnData) {
        uint256 returnDataLength = _callData.length + 2;
        returnData = new bytes[](returnDataLength);

        if (_callData.length > 0) {
            for (uint256 i = 0; i < _callData.length; i++) {
                returnData[i] = _callData[i];
            }
        }

        returnData[returnDataLength - 2] = abi.encodeCall(scCrossAssetYieldVault.supply, (_protocolId, _supplyAmount));
        returnData[returnDataLength - 1] = abi.encodeCall(scCrossAssetYieldVault.borrow, (_protocolId, _borrowAmount));
    }

    function _protocolIdToString(uint256 _protocolId) public view returns (string memory) {
        if (_protocolId == aaveV3.id()) {
            return "Aave v3";
        } else if (_protocolId == aaveV2.id()) {
            return "Aave v2";
        } else if (_protocolId == morpho.id()) {
            return "Euler";
        } else if (_protocolId == morpho.id()) {
            return "Morpho";
        }

        revert("unknown protocol");
    }

    function _usdcBalance() internal view returns (uint256) {
        return vault.asset().balanceOf(address(vault));
    }
}

contract UsdcWethSwapperHarness is UsdcWethSwapper {
    function swapRouter() public pure override(ISwapper, UniversalSwapper) returns (address) {
        return C.ZERO_EX_ROUTER;
    }
}

contract FakeTargetVault is ERC4626 {
    constructor(ERC20 _asset) ERC4626(_asset, "Fake TARGET VAULT", "scFake") {}

    function totalAssets() public pure override returns (uint256) {
        return 1e18;
    }
}
