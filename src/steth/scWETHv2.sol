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
import {PriceConverter} from "./PriceConverter.sol";
import {IAdapter} from "./IAdapter.sol";
import {Swapper} from "./Swapper.sol";
import {BaseV2Vault} from "./BaseV2Vault.sol";

contract scWETHv2 is BaseV2Vault {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using Address for address;
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    event Harvest(uint256 profitSinceLastHarvest, uint256 performanceFee);
    event TokensSwapped(address inToken, address outToken);
    event FloatAmountUpdated(address indexed user, uint256 newFloatAmount);

    // total invested during last harvest/rebalance
    uint256 public totalInvested;

    // total profit generated for this vault
    uint256 public totalProfit;

    uint256 public minimumFloatAmount = 1 ether;

    IwstETH constant wstETH = IwstETH(C.WSTETH);

    constructor(
        address _admin,
        address _keeper,
        uint256 _slippageTolerance, // TODO: do we really need this param?
        WETH _weth,
        Swapper _swapper,
        PriceConverter _priceConverter
    ) BaseV2Vault(_admin, _keeper, _weth, _priceConverter, _swapper, "Sandclock WETH Vault v2", "scWETHv2") {
        if (_slippageTolerance > C.ONE) revert InvalidSlippageTolerance();

        slippageTolerance = _slippageTolerance;
    }

    /////////////////// ADMIN/KEEPER METHODS //////////////////////////////////

    function setSwapper(address _swapper) external {
        _onlyAdmin();
        swapper = Swapper(_swapper);
    }

    /// @notice set the minimum amount of weth that must be present in the vault
    /// @param _newFloatAmount the new minimum float amount
    function setMinimumFloatAmount(uint256 _newFloatAmount) external {
        _onlyAdmin();

        minimumFloatAmount = _newFloatAmount;

        emit FloatAmountUpdated(msg.sender, _newFloatAmount);
    }

    // TODO: this is also common for both scWETH and scETH
    /// @dev to be used to ideally swap wstEth to weth, weth to wstEth during rebalancing using 0x api
    /// @dev can also be used to swap between other tokens
    /// @param _inToken address of the token to swap from
    function swapTokensWith0x(bytes calldata _swapData, address _inToken, uint256 _amountIn, uint256 _amountOutMin)
        external
    {
        _onlyKeeperOrFlashLoan();

        address(swapper).functionDelegateCall(
            abi.encodeWithSelector(Swapper.zeroExSwap.selector, _inToken, asset, _amountIn, _amountOutMin, _swapData)
        );

        // TODO: fix event
        emit TokensSwapped(_inToken, address(asset));
    }

    /// @dev _totalInvestAmount must be zero in case of disinvest or reallocation
    function rebalance(uint256 _totalInvestAmount, uint256 _flashLoanAmount, bytes[] calldata _multicallData)
        external
    {
        _onlyKeeper();

        if (_totalInvestAmount > asset.balanceOf(address(this))) revert InsufficientDepositBalance();

        // needed otherwise counted as profit during harvest
        totalInvested += _totalInvestAmount;

        _flashLoan(_flashLoanAmount, _multicallData);

        _harvest();
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

        uint256 wethAmountOutMin = priceConverter.stEthToEth(stEthAmount).mulWadDown(_slippageTolerance);

        address(swapper).functionDelegateCall(
            abi.encodeWithSelector(Swapper.curveSwapStEthToWeth.selector, stEthAmount, wethAmountOutMin)
        );
    }

    /// @notice withdraw funds from the strategy into the vault
    /// @param _amount : amount of assets to withdraw into the vault
    function withdrawToVault(uint256 _amount) external {
        _onlyKeeper();
        _withdrawToVault(_amount);
    }

    //////////////////// VIEW METHODS //////////////////////////

    /// @notice returns the adapter address given the adapterId (only if the adaapterId is supported else returns zero address)
    /// @param _adapterId the id of the adapter to check
    function getAdapter(uint256 _adapterId) external view returns (address adapter) {
        (, adapter) = protocolAdapters.tryGet(_adapterId);
    }

    /// @notice returns the total assets (in WETH) held by the strategy
    function totalAssets() public view override returns (uint256 assets) {
        // value of the supplied collateral in eth terms using chainlink oracle
        assets = _totalCollateralInWeth();

        // subtract the debt
        assets -= totalDebt();

        // add float
        assets += asset.balanceOf(address(this));
    }

    /// @notice returns the total wstEth supplied as collateral
    function totalCollateral() public view returns (uint256 collateral) {
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

    // TODO: add comment why this is disabled
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

        _multiCall(callData);

        // payback flashloan
        asset.safeTransfer(address(balancerVault), flashLoanAmount);

        _enforceFloat();
    }

    function supplyAndBorrow(uint256 _adapterId, uint256 _supplyAmount, uint256 _borrowAmount) external {
        _onlyKeeperOrFlashLoan();

        address adapter = protocolAdapters.get(_adapterId);

        _adapterDelegateCall(adapter, abi.encodeWithSelector(IAdapter.supply.selector, _supplyAmount));
        _adapterDelegateCall(adapter, abi.encodeWithSelector(IAdapter.borrow.selector, _borrowAmount));
    }

    function repayAndWithdraw(uint256 _adapterId, uint256 _repayAmount, uint256 _withdrawAmount) external {
        _onlyKeeperOrFlashLoan();

        address adapter = protocolAdapters.get(_adapterId);

        _adapterDelegateCall(adapter, abi.encodeWithSelector(IAdapter.repay.selector, _repayAmount));
        _adapterDelegateCall(adapter, abi.encodeWithSelector(IAdapter.withdraw.selector, _withdrawAmount));
    }

    // need to be able to receive eth
    receive() external payable {}

    //////////////////// INTERNAL METHODS //////////////////////////

    function _withdrawToVault(uint256 _amount) internal {
        uint256 n = protocolAdapters.length();
        uint256 flashLoanAmount;
        uint256 totalInvested_ = _totalCollateralInWeth() - totalDebt();
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
                priceConverter.ethToWstEth(flashLoanAmount_ + amount_)
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
        uint256 assets = priceConverter.wstEthToEth(IAdapter(_adapter).getCollateral(address(this))) - debt;

        // withdraw from each protocol based on the allocation percent
        amount = _totalAmount.mulDivDown(assets, _totalInvested);

        // calculate the flashloan amount needed
        flashLoanAmount = amount.mulDivDown(debt, assets);
    }

    function _harvest() internal {
        // store the old total
        uint256 oldTotalInvested = totalInvested;
        uint256 assets = _totalCollateralInWeth() - totalDebt();

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

    function _totalCollateralInWeth() internal view returns (uint256) {
        return priceConverter.wstEthToEth(totalCollateral());
    }
}
