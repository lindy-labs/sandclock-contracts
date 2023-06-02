// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
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
import {Swapper} from "../steth/Swapper.sol";

contract scWETHv2 is sc4626, IFlashLoanRecipient {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using Address for address;
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    event SlippageToleranceUpdated(address indexed admin, uint256 newSlippageTolerance);
    event Harvest(uint256 profitSinceLastHarvest, uint256 performanceFee);
    event TokensSwapped(address inToken, address outToken);
    event FloatAmountUpdated(address indexed user, uint256 newFloatAmount);

    struct ConstructorParams {
        address admin;
        address keeper;
        uint256 slippageTolerance;
        address weth;
        IVault balancerVault;
        OracleLib oracleLib;
        Swapper swapper;
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

    Swapper public swapper;

    IwstETH constant wstETH = IwstETH(C.WSTETH);

    constructor(ConstructorParams memory _params)
        sc4626(_params.admin, _params.keeper, ERC20(_params.weth), "Sandclock WETH Vault v2", "scWETHv2")
    {
        if (_params.slippageTolerance > C.ONE) revert InvalidSlippageTolerance();

        slippageTolerance = _params.slippageTolerance;
        balancerVault = _params.balancerVault;
        oracleLib = _params.oracleLib;

        swapper = _params.swapper;
    }

    /////////////////// ADMIN/KEEPER METHODS //////////////////////////////////

    function setSwapper(address _swapper) external {
        _onlyAdmin();
        swapper = Swapper(_swapper);
    }

    /// @notice set the slippage tolerance for curve swaps
    /// @param _newSlippageTolerance the new slippage tolerance
    /// @dev slippage tolerance is a number between 0 and 1e18
    function setSlippageTolerance(uint256 _newSlippageTolerance) external {
        _onlyAdmin();

        if (_newSlippageTolerance > C.ONE) revert InvalidSlippageTolerance();

        slippageTolerance = _newSlippageTolerance;
        emit SlippageToleranceUpdated(msg.sender, _newSlippageTolerance);
    }

    /// @notice set the minimum amount of weth that must be present in the vault
    /// @param _newFloatAmount the new minimum float amount
    function setMinimumFloatAmount(uint256 _newFloatAmount) external {
        _onlyAdmin();
        minimumFloatAmount = _newFloatAmount;
        emit FloatAmountUpdated(msg.sender, _newFloatAmount);
    }

    /// @notice adds an adapter to the supported adapters
    /// @param _adapter the address of the adapter to add (must inherit IAdapter.sol)
    function addAdapter(address _adapter) external {
        _onlyAdmin();

        uint256 id = IAdapter(_adapter).id();

        if (isSupported(id)) revert ProtocolAlreadySupported();

        protocolAdapters.set(id, _adapter);

        _adapter.functionDelegateCall(abi.encodeWithSelector(IAdapter.setApprovals.selector));
        // TODO: add event
    }

    /// @notice removes an adapter from the supported adapters
    /// @param _adapterId the id of the adapter to remove
    /// @param _force if true, it will not check if there are funds deposited in the respective protocol
    function removeAdapter(uint256 _adapterId, bool _force) external {
        _onlyAdmin();

        if (!isSupported(_adapterId)) revert ProtocolNotSupported(_adapterId);

        address _adapter = protocolAdapters.get(_adapterId);

        if (!_force) {
            if (IAdapter(_adapter).getCollateral(address(this)) != 0) {
                revert ProtocolContainsFunds();
            }
        }

        _adapter.functionDelegateCall(abi.encodeWithSelector(IAdapter.revokeApprovals.selector));
        protocolAdapters.remove(_adapterId);
        // TODO: add event
    }

    /// @dev to be used to ideally swap euler rewards to weth using 0x api
    /// @dev can also be used to swap between other tokens
    /// @param _inToken address of the token to swap from
    function swapTokensWith0x(bytes calldata _swapData, address _inToken, uint256 _amountIn, uint256 _wethAmountOutMin)
        external
    {
        _onlyKeeper();

        address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                Swapper.zeroExSwap.selector, _inToken, asset, _amountIn, _wethAmountOutMin, _swapData
            )
        );

        // TODO: fix event
        emit TokensSwapped(_inToken, address(asset));
    }

    function claimRewards(uint256 _adapterId, bytes calldata _data) external {
        _onlyKeeper();
        protocolAdapters.get(_adapterId).functionDelegateCall(
            abi.encodeWithSelector(IAdapter.claimRewards.selector, _data)
        );
        // TODO: add event
    }

    function investAndHarvest(uint256 _totalInvestAmount, uint256 _flashLoanAmount, bytes[] calldata _multicallData)
        external
    {
        _onlyKeeper();

        if (_totalInvestAmount > asset.balanceOf(address(this))) revert InsufficientDepositBalance();

        // needed otherwise counted as profit during harvest
        totalInvested += _totalInvestAmount;

        _flashLoan(_flashLoanAmount, _multicallData);

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

            // TODO: change name to Harvested
            emit Harvest(profit, fee);
        }
    }

    function swapWethToWstEth(uint256 _wethAmount) external {
        _onlyKeeperOrFlashLoan();

        address(swapper).functionDelegateCall(
            abi.encodeWithSelector(Swapper.lidoSwapWethToWstEth.selector, _wethAmount)
        );
    }

    function swapWstEthToWeth(uint256 _wstEthAmount, uint256 _slippageTolerance) external {
        _onlyKeeperOrFlashLoan();

        uint256 wstEthBalance = wstETH.balanceOf(address(this));

        if (_wstEthAmount > wstEthBalance) {
            _wstEthAmount = wstEthBalance;
        }

        uint256 stEthAmount = wstETH.unwrap(_wstEthAmount);

        uint256 wethAmountOutMin = oracleLib.stEthToEth(stEthAmount).mulWadDown(_slippageTolerance);

        address(swapper).functionDelegateCall(
            abi.encodeWithSelector(Swapper.curveSwapStEthToWeth.selector, stEthAmount, wethAmountOutMin)
        );
    }

    function swapWstEthToWethOnZeroEx(uint256 _wstEthAmount, uint256 _wethAmountOutMin, bytes calldata _swapData)
        external
    {
        _onlyKeeperOrFlashLoan();

        address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                Swapper.zeroExSwap.selector, wstETH, asset, _wstEthAmount, _wethAmountOutMin, _swapData
            )
        );
    }

    /// @notice withdraw funds from the strategy into the vault
    /// @param _amount : amount of assets to withdraw into the vault
    function withdrawToVault(uint256 _amount) external {
        _onlyKeeper();
        _withdrawToVault(_amount);
    }

    function disinvest(uint256 _flashLoanAmount, bytes[] calldata _multicallData) external {
        _onlyKeeper();

        // take flashloan
        _flashLoan(_flashLoanAmount, _multicallData);

        // TODO: fix event
        // emit DisInvested(_repayWithdrawParams);
    }

    // TODO: now reallocate2 and disinvest2 look the same, we can merge them into something like "multicallWithFlashLoan"
    function reallocate(uint256 _flashLoanAmount, bytes[] calldata _multicallData) external {
        _onlyKeeper();

        // take flashloan
        _flashLoan(_flashLoanAmount, _multicallData);

        // TODO: fix event
        // emit Reallocated(_from, _to);
    }

    //////////////////// VIEW METHODS //////////////////////////

    /// @notice check if an adapter is supported by this vault
    /// @param _adapterId the id of the adapter to check
    function isSupported(uint256 _adapterId) public view returns (bool) {
        return protocolAdapters.contains(_adapterId);
    }

    /// @notice returns the adapter address given the adapterId (only if the adaapterId is supported else returns zero address)
    /// @param _adapterId the id of the adapter to check
    function getAdapter(uint256 _adapterId) external view returns (address adapter) {
        (, adapter) = protocolAdapters.tryGet(_adapterId);
    }

    /// @notice returns the total assets (in WETH) held by the strategy
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

        // TODO: I wouldn't use this coversion here since it's confusing to have collateral returned in weth and repaying debt in wstEth
        collateral = oracleLib.wstEthToEth(collateral);
    }

    // TODO: would prefer to use this instead of the above because we are supplying and withdrawing wstEth and not eth
    function totalCollateral2() public view returns (uint256 collateral) {
        uint256 n = protocolAdapters.length();
        address adapter;
        for (uint256 i; i < n; i++) {
            (, adapter) = protocolAdapters.at(i);
            collateral += IAdapter(adapter).getCollateral(address(this));
        }
    }

    /// @notice returns the total WETH borrowed
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
    /// @param receiver the address to mint the shares to
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
        _isFlashLoanInitiated();

        // the amount flashloaned
        uint256 flashLoanAmount = amounts[0];

        // decode user data
        bytes[] memory callData = abi.decode(userData, (bytes[]));

        for (uint256 i = 0; i < callData.length; i++) {
            address(this).functionDelegateCall(callData[i]);
        }

        // payback flashloan
        asset.safeTransfer(address(balancerVault), flashLoanAmount);

        _enforceFloat();
    }

    // need to be able to receive eth
    receive() external payable {}

    //////////////////// INTERNAL METHODS //////////////////////////

    function _withdrawToVault(uint256 _amount) internal {
        uint256 n = protocolAdapters.length();
        uint256 flashLoanAmount;
        uint256 totalInvested_ = totalCollateral() - totalDebt();
        bytes[] memory callData = new bytes[](n + 1);

        uint256 flashLoanAmount_;
        uint256 amount_;
        uint256 adapterId;
        address adapter;
        for (uint256 i; i < n; i++) {
            (adapterId, adapter) = protocolAdapters.at(i);
            (flashLoanAmount_, amount_) = _calcFlashLoanAmountWithdrawing(adapter, _amount, totalInvested_);

            flashLoanAmount += flashLoanAmount_;

            callData[i] = abi.encodeWithSelector(
                this.repayAndWithdraw.selector,
                adapterId,
                flashLoanAmount_,
                oracleLib.ethToWstEth(flashLoanAmount_ + amount_)
            );
        }

        // needed otherwise counted as loss during harvest
        totalInvested -= _amount;

        callData[n] = abi.encodeWithSelector(scWETHv2.swapWstEthToWeth.selector, type(uint256).max, slippageTolerance);

        // take flashloan
        _flashLoan(flashLoanAmount, callData);
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

    function supplyAndBorrow(uint256 _adapterId, uint256 _supplyAmount, uint256 _borrowAmount) external {
        _onlyKeeperOrFlashLoan();

        address adapter = protocolAdapters.get(_adapterId);

        _adapterDelegateCall(adapter, IAdapter.supply.selector, _supplyAmount);
        _adapterDelegateCall(adapter, IAdapter.borrow.selector, _borrowAmount);
    }

    function repayAndWithdraw(uint256 _adapterId, uint256 _repayAmount, uint256 _withdrawAmount) external {
        _onlyKeeperOrFlashLoan();

        address adapter = protocolAdapters.get(_adapterId);

        _adapterDelegateCall(adapter, IAdapter.repay.selector, _repayAmount);
        _adapterDelegateCall(adapter, IAdapter.withdraw.selector, _withdrawAmount);
    }

    function _adapterDelegateCall(address _adapter, bytes4 _selector, uint256 _amount) internal {
        _adapter.functionDelegateCall(abi.encodeWithSelector(_selector, _amount));
    }

    function _flashLoan(uint256 _totalFlashLoanAmount, bytes[] memory callData) internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(asset);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _totalFlashLoanAmount;

        _initiateFlashLoan();
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(callData));
        _finalizeFlashLoan();
    }

    function _calcFlashLoanAmountWithdrawing(address _adapter, uint256 _totalAmount, uint256 _totalInvested)
        internal
        view
        returns (uint256 flashLoanAmount, uint256 amount)
    {
        uint256 debt = IAdapter(_adapter).getDebt(address(this));
        uint256 assets = oracleLib.wstEthToEth(IAdapter(_adapter).getCollateral(address(this))) - debt;

        // withdraw from each protocol based on the allocation percent
        amount = _totalAmount.mulDivDown(assets, _totalInvested);

        // calculate the flashloan amount needed
        flashLoanAmount = amount.mulDivDown(debt, assets);
    }
}
