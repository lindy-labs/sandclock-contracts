// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console.sol";

import {
    InvalidTargetLtv,
    ZeroAddress,
    InvalidSlippageTolerance,
    PleaseUseRedeemMethod,
    InvalidFlashLoanCaller,
    InvalidAllocationPercents,
    InsufficientDepositBalance,
    FloatBalanceTooSmall,
    TokenSwapFailed,
    AmountReceivedBelowMin,
    ProtocolAlreadySupported,
    ProtocolNotSupported,
    ProtocolContainsFunds
} from "../errors/scErrors.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IEulerMarkets} from "lib/euler-interfaces/contracts/IEuler.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
// import {EnumerableSet} from "openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {EnumerableMap} from "openzeppelin-contracts/utils/structs/EnumerableMap.sol";

import {Constants as C} from "../lib/Constants.sol";
import {sc4626} from "../sc4626.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {ILido} from "../interfaces/lido/ILido.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";
import {OracleLib} from "./OracleLib.sol";
import {IAdapter} from "../scWeth-adapters/IAdapter.sol";
import {ISwapRouter} from "../swap-routers/ISwapRouter.sol";

contract scWETHv2 is sc4626, IFlashLoanRecipient {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using Address for address;
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    event SlippageToleranceUpdated(address indexed admin, uint256 newSlippageTolerance);
    event Harvest(uint256 profitSinceLastHarvest, uint256 performanceFee);
    event Invested(uint256 amount, SupplyBorrowParam[] supplyBorrowParams);
    event DisInvested(RepayWithdrawParam[] repayWithdrawParams);
    event Reallocated(RepayWithdrawParam[] from, SupplyBorrowParam[] to);
    event TokensSwapped(address inToken, address outToken);
    event FloatAmountUpdated(address indexed user, uint256 newFloatAmount);

    struct RebalanceParams {
        RepayWithdrawParam[] repayWithdrawParams;
        SupplyBorrowParam[] supplyBorrowParams;
        bytes wstEthToWethSwapData;
        bytes wethToWstEthSwapData;
    }

    struct RepayWithdrawParam {
        uint256 protocolId;
        uint256 repayAmount; // flashLoanAmount (in WETH)
        uint256 withdrawAmount; // amount of wstEth to withdraw from the market (amount + flashLoanAmount) (in wstEth)
    }

    struct SupplyBorrowParam {
        uint256 protocolId;
        uint256 supplyAmount; // amount of wstEth to supply to the market (in wstEth)
        uint256 borrowAmount; // flashLoanAmount (in WETH)
    }

    struct ConstructorParams {
        address admin;
        address keeper;
        uint256 slippageTolerance;
        address weth;
        IVault balancerVault;
        OracleLib oracleLib;
        address wstEthToWethSwapRouter;
        address wethToWstEthSwapRouter;
    }

    // total invested during last harvest/rebalance
    uint256 public totalInvested;

    // total profit generated for this vault
    uint256 public totalProfit;

    // slippage for curve swaps
    uint256 public slippageTolerance;
    uint256 public minimumFloatAmount = 1 ether;

    // Balancer vault for flashloans
    IVault public immutable balancerVault;

    // external contracts
    OracleLib immutable oracleLib;

    EnumerableMap.UintToAddressMap private protocolAdapters;

    address public wstEthToWethSwapRouter;
    address public wethToWstEthSwapRouter;

    constructor(ConstructorParams memory params)
        sc4626(params.admin, params.keeper, ERC20(params.weth), "Sandclock WETH Vault v2", "scWETHv2")
    {
        if (params.slippageTolerance > C.ONE) revert InvalidSlippageTolerance();
        slippageTolerance = params.slippageTolerance;
        balancerVault = params.balancerVault;
        oracleLib = params.oracleLib;
        wstEthToWethSwapRouter = params.wstEthToWethSwapRouter;
        wethToWstEthSwapRouter = params.wethToWstEthSwapRouter;
    }

    /////////////////// ADMIN/KEEPER METHODS //////////////////////////////////

    function setSwapRouter(address _wstEthToWethSwapRouter, address _wethToWstEthSwapRouter) external {
        onlyAdmin();
        if (_wstEthToWethSwapRouter != address(0x0)) wstEthToWethSwapRouter = _wstEthToWethSwapRouter;
        if (_wethToWstEthSwapRouter != address(0x0)) wethToWstEthSwapRouter = _wethToWstEthSwapRouter;
    }

    /// @notice set the slippage tolerance for curve swaps
    /// @param newSlippageTolerance the new slippage tolerance
    /// @dev slippage tolerance is a number between 0 and 1e18
    function setSlippageTolerance(uint256 newSlippageTolerance) external {
        onlyAdmin();
        if (newSlippageTolerance > C.ONE) revert InvalidSlippageTolerance();
        slippageTolerance = newSlippageTolerance;
        emit SlippageToleranceUpdated(msg.sender, newSlippageTolerance);
    }

    function setMinimumFloatAmount(uint256 newFloatAmount) external {
        onlyAdmin();
        minimumFloatAmount = newFloatAmount;
        emit FloatAmountUpdated(msg.sender, newFloatAmount);
    }

    function addAdapter(address _adapter) external {
        onlyAdmin();

        uint256 id = IAdapter(_adapter).id();

        if (isSupported(id)) revert ProtocolAlreadySupported();

        protocolAdapters.set(id, _adapter);

        _adapter.functionDelegateCall(abi.encodeWithSelector(IAdapter.setApprovals.selector));
    }

    /// @notice removes an adapter from the supported adapters
    /// @param _adapterId the id of the adapter to remove
    /// @param _checkForFunds if true, will revert if the vault still has funds deposited in the adapter
    function removeAdapter(uint256 _adapterId, bool _checkForFunds) external {
        onlyAdmin();
        if (!isSupported(_adapterId)) revert ProtocolNotSupported();
        address _adapter = protocolAdapters.get(_adapterId);
        if (_checkForFunds) {
            if (IAdapter(_adapter).getCollateral(address(this)) != 0) {
                revert ProtocolContainsFunds();
            }
        }
        _adapter.functionDelegateCall(abi.encodeWithSelector(IAdapter.revokeApprovals.selector));
        protocolAdapters.remove(_adapterId);
    }

    /// @dev to be used to ideally swap euler rewards to weth using 0x api
    /// @dev can also be used to swap between other tokens
    /// @param inToken address of the token to swap from
    function swapTokensWith0x(bytes calldata swapData, address inToken, address outToken, uint256 amountIn) external {
        onlyKeeper();
        ERC20(inToken).safeApprove(C.ZEROX_ROUTER, amountIn);
        C.ZEROX_ROUTER.functionCall(swapData);

        emit TokensSwapped(inToken, outToken);
    }

    function claimRewards(uint256 _adapterId, bytes calldata _data) external {
        onlyKeeper();
        protocolAdapters.get(_adapterId).functionDelegateCall(
            abi.encodeWithSelector(IAdapter.claimRewards.selector, _data)
        );
    }

    /// @notice invest funds into the strategy and harvest profits if any
    /// @dev for the first deposit, deposits everything into the strategy.
    /// @dev also mints performance fee tokens to the treasury
    function investAndHarvest(
        uint256 totalInvestAmount,
        SupplyBorrowParam[] calldata supplyBorrowParams,
        bytes calldata wethToWstEthSwapData
    ) external {
        onlyKeeper();
        invest(totalInvestAmount, supplyBorrowParams, wethToWstEthSwapData);

        // store the old total
        uint256 oldTotalInvested = totalInvested;
        uint256 assets = totalCollateral() - totalDebt();

        if (assets > oldTotalInvested) {
            totalInvested = assets;

            // profit since last harvest, zero if there was a loss
            uint256 profit = assets - oldTotalInvested;
            totalProfit += profit;

            uint256 fee = profit.mulWadDown(performanceFee);

            // mint equivalent amount of tokens to the performance fee beneficiary ie the treasury
            _mint(treasury, convertToShares(fee));

            emit Harvest(profit, fee);
        }
    }

    /// @notice withdraw funds from the strategy into the vault
    /// @param amount : amount of assets to withdraw into the vault
    function withdrawToVault(uint256 amount) external {
        onlyKeeper();
        _withdrawToVault(amount);
    }

    /// @notice invest funds into the strategy (or reinvesting profits)
    /// @param totalInvestAmount : amount of weth to invest into the strategy
    /// @param supplyBorrowParams : protocols to invest into and their respective amounts
    function invest(
        uint256 totalInvestAmount,
        SupplyBorrowParam[] calldata supplyBorrowParams,
        bytes calldata wethToWstEthSwapData
    ) internal {
        if (totalInvestAmount > asset.balanceOf(address(this))) revert InsufficientDepositBalance();

        uint256 totalFlashLoanAmount;
        for (uint256 i; i < supplyBorrowParams.length; i++) {
            totalFlashLoanAmount += supplyBorrowParams[i].borrowAmount;
        }

        scWETHv2.RebalanceParams memory params = scWETHv2.RebalanceParams({
            repayWithdrawParams: new scWETHv2.RepayWithdrawParam[](0),
            supplyBorrowParams: supplyBorrowParams,
            wstEthToWethSwapData: "",
            wethToWstEthSwapData: wethToWstEthSwapData
        });

        // needed otherwise counted as profit during harvest
        totalInvested += totalInvestAmount;

        _flashLoan(totalFlashLoanAmount, params);

        emit Invested(totalInvestAmount, supplyBorrowParams);
    }

    /// @notice disinvest from lending markets in case of a loss
    /// @param repayWithdrawParams : protocols to disinvest from and their respective amounts
    function disinvest(RepayWithdrawParam[] calldata repayWithdrawParams, bytes calldata wstEthToWethSwapData)
        external
    {
        onlyKeeper();
        uint256 totalFlashLoanAmount;
        for (uint256 i; i < repayWithdrawParams.length; i++) {
            totalFlashLoanAmount += repayWithdrawParams[i].repayAmount;
        }

        RebalanceParams memory params = RebalanceParams({
            repayWithdrawParams: repayWithdrawParams,
            supplyBorrowParams: new SupplyBorrowParam[](0),
            wstEthToWethSwapData: wstEthToWethSwapData,
            wethToWstEthSwapData: ""
        });

        // take flashloan
        _flashLoan(totalFlashLoanAmount, params);

        emit DisInvested(repayWithdrawParams);
    }

    /// @notice reallocate funds between protocols (without any slippage)
    // @param wstEthSwapAmount: amount of wstEth to swap to weth
    function reallocate(
        RepayWithdrawParam[] calldata from,
        SupplyBorrowParam[] calldata to,
        bytes calldata wstEthToWethSwapData,
        bytes calldata wethToWstEthSwapData
    ) external {
        onlyKeeper();
        uint256 totalFlashLoanAmount;
        for (uint256 i; i < from.length; i++) {
            totalFlashLoanAmount += from[i].repayAmount;
        }

        RebalanceParams memory params = RebalanceParams({
            repayWithdrawParams: from,
            supplyBorrowParams: to,
            wstEthToWethSwapData: wstEthToWethSwapData,
            wethToWstEthSwapData: wethToWstEthSwapData
        });

        // take flashloan
        _flashLoan(totalFlashLoanAmount, params);

        emit Reallocated(from, to);
    }

    //////////////////// VIEW METHODS //////////////////////////

    function isSupported(uint256 _adapterId) public view returns (bool) {
        return protocolAdapters.contains(_adapterId);
    }

    function getAdapter(uint256 _adapterId) external view returns (address adapter) {
        (, adapter) = protocolAdapters.tryGet(_adapterId);
    }

    /// @notice returns the total assets (WETH) held by the strategy
    function totalAssets() public view override returns (uint256 assets) {
        // value of the supplied collateral in eth terms using chainlink oracle
        assets = totalCollateral();

        // subtract the debt
        assets -= totalDebt();

        // add float
        assets += asset.balanceOf(address(this));
    }

    /// @notice returns the total assets supplied as collateral (in WETH terms)
    function totalCollateral() public view returns (uint256 collateral) {
        uint256 n = protocolAdapters.length();
        address adapter;
        for (uint256 i; i < n; i++) {
            (, adapter) = protocolAdapters.at(i);
            collateral += IAdapter(adapter).getCollateral(address(this));
        }

        collateral = oracleLib.wstEthToEth(collateral);
    }

    /// @notice returns the total ETH borrowed
    function totalDebt() public view returns (uint256 debt) {
        uint256 n = protocolAdapters.length();
        address adapter;
        for (uint256 i; i < n; i++) {
            (, adapter) = protocolAdapters.at(i);
            debt += IAdapter(adapter).getDebt(address(this));
        }
    }

    //////////////////// EXTERNAL METHODS //////////////////////////

    /// @notice helper method to directly deposit ETH instead of weth
    function deposit(address receiver) external payable returns (uint256 shares) {
        uint256 assets = msg.value;

        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        // wrap eth
        WETH(payable(address(asset))).deposit{value: assets}();

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    function withdraw(uint256, address, address) public virtual override returns (uint256) {
        revert PleaseUseRedeemMethod();
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        beforeWithdraw(assets, shares);

        _burn(owner, shares);

        uint256 balance = asset.balanceOf(address(this));

        if (assets > balance) {
            assets = balance;
        }

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        asset.safeTransfer(receiver, assets);
    }

    /// @dev called after the flashLoan on rebalance
    function receiveFlashLoan(address[] memory, uint256[] memory amounts, uint256[] memory, bytes memory userData)
        external
    {
        if (msg.sender != address(balancerVault)) {
            revert InvalidFlashLoanCaller();
        }

        _isFlashLoanInitiated();

        // the amount flashloaned
        uint256 flashLoanAmount = amounts[0];

        // decode user data
        (RebalanceParams memory rebalanceParams) = abi.decode(userData, (RebalanceParams));

        // repay and withdraw first
        for (uint8 i; i < rebalanceParams.repayWithdrawParams.length; i++) {
            _repayWithdraw(rebalanceParams.repayWithdrawParams[i]);
        }

        if (rebalanceParams.wstEthToWethSwapData.length != 0) {
            // wstEth to weth
            wstEthToWethSwapRouter.functionDelegateCall(rebalanceParams.wstEthToWethSwapData);
        }

        if (rebalanceParams.wethToWstEthSwapData.length != 0) {
            // weth to wstEth
            wethToWstEthSwapRouter.functionDelegateCall(rebalanceParams.wethToWstEthSwapData);
        }

        for (uint8 i; i < rebalanceParams.supplyBorrowParams.length; i++) {
            _supplyBorrow(rebalanceParams.supplyBorrowParams[i]);
        }

        // payback flashloan
        asset.safeTransfer(address(balancerVault), flashLoanAmount);

        _enforceFloat();
    }

    // need to be able to receive eth
    receive() external payable {}

    //////////////////// INTERNAL METHODS //////////////////////////

    function _withdrawToVault(uint256 amount) internal {
        uint256 n = protocolAdapters.length();
        uint256 flashLoanAmount;
        RepayWithdrawParam[] memory repayWithdrawParams = new RepayWithdrawParam[](n);

        uint256 totalInvested_ = totalCollateral() - totalDebt();

        {
            uint256 flashLoanAmount_;
            uint256 amount_;
            uint256 protocolId;
            address adapter;
            for (uint256 i; i < n; i++) {
                (protocolId, adapter) = protocolAdapters.at(i);
                (flashLoanAmount_, amount_) = oracleLib.calcFlashLoanAmountWithdrawing(adapter, amount, totalInvested_);

                repayWithdrawParams[i] =
                    RepayWithdrawParam(protocolId, flashLoanAmount_, oracleLib.ethToWstEth(flashLoanAmount_ + amount_));
                flashLoanAmount += flashLoanAmount_;
            }
        }

        // needed otherwise counted as loss during harvest
        totalInvested -= amount;

        SupplyBorrowParam[] memory empty;
        RebalanceParams memory params = RebalanceParams({
            repayWithdrawParams: repayWithdrawParams,
            supplyBorrowParams: empty,
            wstEthToWethSwapData: abi.encodeWithSelector(
                ISwapRouter.swapDefault.selector, type(uint256).max, slippageTolerance
                ),
            wethToWstEthSwapData: ""
        });

        // take flashloan
        _flashLoan(flashLoanAmount, params);
    }

    /// @notice enforce float to be above the minimum required
    function _enforceFloat() internal view {
        uint256 float = asset.balanceOf(address(this));
        uint256 floatRequired = minimumFloatAmount;
        if (float < floatRequired) {
            revert FloatBalanceTooSmall(float, floatRequired);
        }
    }

    function beforeWithdraw(uint256 assets, uint256) internal override {
        uint256 float = asset.balanceOf(address(this));
        if (assets <= float) {
            return;
        }

        uint256 minimumFloat = minimumFloatAmount;
        uint256 floatRequired = float < minimumFloat ? minimumFloat - float : 0;
        uint256 missing = assets + floatRequired - float;

        _withdrawToVault(missing);
    }

    function _supplyBorrow(SupplyBorrowParam memory params) internal {
        address adapter = protocolAdapters.get(params.protocolId);
        adapter.functionDelegateCall(abi.encodeWithSelector(IAdapter.supply.selector, params.supplyAmount));
        adapter.functionDelegateCall(abi.encodeWithSelector(IAdapter.borrow.selector, params.borrowAmount));
    }

    function _repayWithdraw(RepayWithdrawParam memory params) internal {
        address adapter = protocolAdapters.get(params.protocolId);
        adapter.functionDelegateCall(abi.encodeWithSelector(IAdapter.repay.selector, params.repayAmount));
        adapter.functionDelegateCall(abi.encodeWithSelector(IAdapter.withdraw.selector, params.withdrawAmount));
    }

    function _flashLoan(uint256 _totalFlashLoanAmount, RebalanceParams memory _params) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(asset);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _totalFlashLoanAmount;

        _initiateFlashLoan();
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(_params));
        _finalizeFlashLoan();
    }
}

// todo:
// gas optimizations
// call with nenad to make contract function signatures similar
