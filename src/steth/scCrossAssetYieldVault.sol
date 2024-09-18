// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {NoProfitsToSell, FlashLoanAmountZero, EndAssetBalanceTooLow, FloatBalanceTooLow} from "../errors/scErrors.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {EnumerableMap} from "openzeppelin-contracts/utils/structs/EnumerableMap.sol";

import {Constants as C} from "../lib/Constants.sol";
import {BaseV2Vault} from "./BaseV2Vault.sol";
import {IAdapter} from "./IAdapter.sol";
import {ISinglePairPriceConverter} from "./priceConverter/ISinglePairPriceConverter.sol";
import {ISinglePairSwapper} from "./swapper/ISinglePairSwapper.sol";

/**
 * @title scCrossAssetYieldVault
 * @notice An abstract vault contract implementing cross-asset yield strategies.
 * @dev Cross-asset means that the yield generated in the target vault (target tokens) is converted to the underlying asset token of the vault.
 * @dev Inherits from BaseV2Vault and provides functionalities to interact with multiple lending markets.
 */
abstract contract scCrossAssetYieldVault is BaseV2Vault {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using Address for address;
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    enum FlashLoanType {
        Reallocate,
        ExitAllPositions
    }

    event EmergencyExitExecuted(
        address indexed admin, uint256 targetTokenWithdrawn, uint256 debtRepaid, uint256 collateralReleased
    );
    event Reallocated();
    event Rebalanced(uint256 totalCollateral, uint256 totalDebt, uint256 floatBalance);
    event ProfitSold(uint256 targetTokenSold, uint256 assetReceived);
    event Supplied(uint256 adapterId, uint256 amount);
    event Borrowed(uint256 adapterId, uint256 amount);
    event Repaid(uint256 adapterId, uint256 amount);
    event Withdrawn(uint256 adapterId, uint256 amount);
    event Invested(uint256 targetTokenAmount);
    event Disinvested(uint256 targetTokenAmount);

    /// @notice The target vault (staking vault) where target tokens are invested.
    ERC4626 public immutable targetVault;

    /// @notice The target token used as underlying in the target vault.
    ERC20 public immutable targetToken;

    constructor(
        address _admin,
        address _keeper,
        ERC20 _asset,
        ERC4626 _targetVault,
        ISinglePairPriceConverter _priceConverter,
        ISinglePairSwapper _swapper,
        string memory _name,
        string memory _symbol
    ) BaseV2Vault(_admin, _keeper, _asset, _priceConverter, _swapper, _name, _symbol) {
        _zeroAddressCheck(address(_targetVault));

        targetVault = _targetVault;
        targetToken = targetVault.asset();

        targetToken.safeApprove(address(_targetVault), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC API
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Rebalance the vault's positions and loans across multiple lending markets.
     * @dev Called to adjust the target token debt, maintain the desired LTV and avoid liquidation.
     * @param _callData An array of encoded function calls to be executed.
     */
    function rebalance(bytes[] calldata _callData) external {
        _onlyKeeper();

        _multiCall(_callData);

        // Invest any remaining target token amount after rebalancing
        _invest();

        // Enforce float to be above the minimum required
        uint256 float = assetBalance();
        uint256 floatRequired = totalAssets().mulWadDown(floatPercentage);

        if (float < floatRequired) {
            revert FloatBalanceTooLow(float, floatRequired);
        }

        emit Rebalanced(totalCollateral(), totalDebt(), float);
    }

    /**
     * @notice Reallocate collateral and debt between lending markets.
     * @dev Uses flash loans to repay debt and release collateral in one market to move to another.
     * @param _flashLoanAmount The amount of target tokens to flash loan.
     * @param _callData An array of encoded function calls to be executed.
     */
    function reallocate(uint256 _flashLoanAmount, bytes[] calldata _callData) external {
        _onlyKeeper();

        if (_flashLoanAmount == 0) revert FlashLoanAmountZero();

        address[] memory tokens = new address[](1);
        tokens[0] = address(targetToken);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _flashLoanAmount;

        _initiateFlashLoan();
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(FlashLoanType.Reallocate, _callData));
        _finalizeFlashLoan();

        emit Reallocated();
    }

    /**
     * @notice Sells profits (in taget tokens) by swapping to the asset token.
     * @dev The vault generates yield in target tokens; profits are sold to asse tokenst.
     * @param _assetAmountOutMin The minimum amount of asset tokens to receive.
     */
    function sellProfit(uint256 _assetAmountOutMin) external {
        _onlyKeeper();

        uint256 profit = _calculateProfitInTargetToken(targetTokenInvestedAmount(), totalDebt());

        if (profit == 0) revert NoProfitsToSell();

        uint256 withdrawn = _disinvest(profit);
        uint256 assetReceived = _swapTargetTokenForAsset(withdrawn, _assetAmountOutMin);

        emit ProfitSold(withdrawn, assetReceived);
    }

    /**
     * @notice Emergency exit to disinvest everything, repay all debt, and withdraw all collateral.
     * @dev Closes all positions to release assets and realize any losses.
     * @param _endAssetBalanceMin The minimum asset balance expected after execution.
     */
    function exitAllPositions(uint256 _endAssetBalanceMin) external {
        _onlyKeeper();

        uint256 collateral = totalCollateral();
        uint256 debt = totalDebt();
        uint256 targetTokenBalance =
            targetVault.redeem(targetVault.balanceOf(address(this)), address(this), address(this));

        if (debt > targetTokenBalance) {
            // not enough target tokens to repay all debt, flashloan the difference
            address[] memory tokens = new address[](1);
            tokens[0] = address(targetToken);

            uint256[] memory amounts = new uint256[](1);
            amounts[0] = debt - targetTokenBalance;

            _initiateFlashLoan();
            balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(FlashLoanType.ExitAllPositions));
            _finalizeFlashLoan();
        } else {
            _repayAllDebtAndWithdrawCollateral();

            // Swap remaining target tokens to asset if any
            uint256 targetTokenLeft = _targetTokenBalance();

            if (targetTokenLeft != 0) _swapTargetTokenForAsset(targetTokenLeft, 0);
        }

        if (assetBalance() < _endAssetBalanceMin) revert EndAssetBalanceTooLow();

        emit EmergencyExitExecuted(msg.sender, targetTokenBalance, debt, collateral);
    }

    /**
     * @notice Handles flashloan callbacks.
     * @dev Called by Balancer's vault in 2 situations:
     * 1. When the vault is underwater and the vault needs to exit all positions.
     * 2. When the vault needs to reallocate capital between lending markets.
     * @param _amounts single elment array containing the amount of target tokens being flashloaned.
     * @param _data The encoded data that was passed to the flashloan.
     */
    function receiveFlashLoan(
        address[] calldata,
        uint256[] calldata _amounts,
        uint256[] calldata _feeAmounts,
        bytes calldata _data
    ) external {
        _isFlashLoanInitiated();

        uint256 flashLoanAmount = _amounts[0];
        FlashLoanType flashLoanType = abi.decode(_data, (FlashLoanType));

        if (flashLoanType == FlashLoanType.ExitAllPositions) {
            _repayAllDebtAndWithdrawCollateral();
            _swapAssetForExactTargetToken(flashLoanAmount);
        } else {
            (, bytes[] memory callData) = abi.decode(_data, (FlashLoanType, bytes[]));
            _multiCall(callData);
        }

        targetToken.safeTransfer(address(balancerVault), flashLoanAmount + _feeAmounts[0]);
    }

    /**
     * @notice Supply asset tokens to a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _amount The amount of asset tokens to supply.
     */
    function supply(uint256 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _supply(_adapterId, _amount);
    }

    /**
     * @notice Borrow an amount of target tokens from a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _amount The amount of target tokens to borrow.
     */
    function borrow(uint256 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _borrow(_adapterId, _amount);
    }

    /**
     * @notice Repay an amount of debt to a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _amount The amount of target tokens to repay.
     */
    function repay(uint256 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _repay(_adapterId, _amount);
    }

    /**
     * @notice Withdraw asset tokens from a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _amount The amount of asset tokens to withdraw.
     */
    function withdraw(uint256 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _withdraw(_adapterId, _amount);
    }

    /**
     * @notice Withdraw target tokens from the target vault.
     * @param _amount The amount of target tokens to withdraw.
     */
    function disinvest(uint256 _amount) external {
        _onlyKeeper();

        _disinvest(_amount);
    }

    /**
     * @notice Returns the total claimable assets of the vault in asset tokens.
     * @return The total assets managed by the vault.
     */
    function totalAssets() public view override returns (uint256) {
        return _calculateTotalAssets(assetBalance(), totalCollateral(), targetTokenInvestedAmount(), totalDebt());
    }

    /**
     * @notice Returns the asset balance of the vault.
     * @return The balance of asset tokens held by the vault.
     */
    function assetBalance() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Returns the amount of asset tokens supplied as collateral in a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @return The amount of collateral supplied in the specified lending market.
     */
    function getCollateral(uint256 _adapterId) external view returns (uint256) {
        if (!isSupported(_adapterId)) return 0;

        return IAdapter(protocolAdapters.get(_adapterId)).getCollateral(address(this));
    }

    /**
     * @notice Returns the total amount of asset tokens supplied as collateral in all lending markets.
     * @return total The total collateral across all lending markets.
     */
    function totalCollateral() public view returns (uint256 total) {
        uint256 length = protocolAdapters.length();

        for (uint256 i = 0; i < length; i++) {
            (, address adapter) = protocolAdapters.at(i);
            total += IAdapter(adapter).getCollateral(address(this));
        }
    }

    /**
     * @notice Returns the amount of target tokens borrowed from a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @return The amount of debt in target tokens for the specified lending market.
     */
    function getDebt(uint256 _adapterId) external view returns (uint256) {
        if (!isSupported(_adapterId)) return 0;

        return IAdapter(protocolAdapters.get(_adapterId)).getDebt(address(this));
    }

    /**
     * @notice Returns the total amount of target tokens borrowed across all lending markets.
     * @return total The total debt in target tokens across all lending markets.
     */
    function totalDebt() public view returns (uint256 total) {
        uint256 length = protocolAdapters.length();

        for (uint256 i = 0; i < length; i++) {
            (, address adapter) = protocolAdapters.at(i);
            total += IAdapter(adapter).getDebt(address(this));
        }
    }

    /**
     * @notice Returns the amount of target tokens invested (staked) in the target vault.
     * @return The amount of target tokens invested in the target vault.
     */
    function targetTokenInvestedAmount() public view returns (uint256) {
        return targetVault.convertToAssets(targetVault.balanceOf(address(this)));
    }

    /**
     * @notice Returns the amount of profit (in target tokens) made by the vault.
     * @dev Profit is calculated as the difference between invested and owed target token amounts.
     * @return The amount of profit in target tokens.
     */
    function getProfit() public view returns (uint256) {
        return _calculateProfitInTargetToken(targetTokenInvestedAmount(), totalDebt());
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Supplies asset tokens to a lending market adapter.
     * @param _adapterId The ID of the adapter.
     * @param _amount The amount of asset tokens to supply.
     */
    function _supply(uint256 _adapterId, uint256 _amount) internal {
        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.supply.selector, _amount));

        emit Supplied(_adapterId, _amount);
    }

    /**
     * @notice Borrows target tokens from a lending market adapter.
     * @param _adapterId The ID of the adapter.
     * @param _amount The amount of target tokens to borrow.
     */
    function _borrow(uint256 _adapterId, uint256 _amount) internal {
        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.borrow.selector, _amount));

        emit Borrowed(_adapterId, _amount);
    }

    /**
     * @notice Repays debt in target tokens to a lending market adapter.
     * @param _adapterId The ID of the adapter.
     * @param _amount The amount of debt to repay.
     */
    function _repay(uint256 _adapterId, uint256 _amount) internal {
        uint256 targetTokenBalance = _targetTokenBalance();

        _amount = _amount > targetTokenBalance ? targetTokenBalance : _amount;

        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.repay.selector, _amount));

        emit Repaid(_adapterId, _amount);
    }

    /**
     * @notice Withdraws asset tokens from a lending market adapter.
     * @param _adapterId The ID of the adapter.
     * @param _amount The amount of asset tokens to withdraw.
     */
    function _withdraw(uint256 _adapterId, uint256 _amount) internal {
        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.withdraw.selector, _amount));

        emit Withdrawn(_adapterId, _amount);
    }

    /**
     * @notice Invests any available target tokens into the target vault.
     */
    function _invest() internal {
        uint256 targetTokenBalance = _targetTokenBalance();

        if (targetTokenBalance > 0) {
            targetVault.deposit(targetTokenBalance, address(this));

            emit Invested(targetTokenBalance);
        }
    }

    /**
     * @notice Disinvests (withdraws) target tokens from the target vault.
     * @param _targetTokenAmount The amount of target tokens to disinvest.
     * @return The amount of target tokens withdrawn.
     */
    function _disinvest(uint256 _targetTokenAmount) internal returns (uint256) {
        uint256 shares = targetVault.convertToShares(_targetTokenAmount);

        uint256 amount = targetVault.redeem(shares, address(this), address(this));

        emit Disinvested(amount);

        return amount;
    }

    /**
     * @notice Repays all debt and withdraws all collateral from all lending markets.
     */
    function _repayAllDebtAndWithdrawCollateral() internal {
        uint256 length = protocolAdapters.length();

        for (uint256 i = 0; i < length; i++) {
            (uint256 id, address adapter) = protocolAdapters.at(i);
            uint256 debt = IAdapter(adapter).getDebt(address(this));
            uint256 collateral = IAdapter(adapter).getCollateral(address(this));

            if (debt > 0) _repay(id, debt);
            if (collateral > 0) _withdraw(id, collateral);
        }
    }

    /**
     * @notice Hook called before withdrawing assets.
     * @param _assets The amount of assets to withdraw.
     */
    function beforeWithdraw(uint256 _assets, uint256) internal override {
        uint256 initialBalance = assetBalance();
        if (initialBalance >= _assets) return;

        uint256 collateral = totalCollateral();
        uint256 debt = totalDebt();
        uint256 invested = targetTokenInvestedAmount();
        uint256 total = _calculateTotalAssets(initialBalance, collateral, invested, debt);
        uint256 profit = _calculateProfitInTargetToken(invested, debt);

        uint256 floatRequired = total > _assets ? (total - _assets).mulWadUp(floatPercentage) : 0;
        uint256 assetNeeded = _assets + floatRequired - initialBalance;

        // first try to sell profits to cover withdrawal amount
        if (profit != 0) {
            uint256 withdrawn = _disinvest(profit);

            uint256 assetAmountOutMin = converter().targetTokenToAsset(withdrawn).mulWadDown(slippageTolerance);
            uint256 assetReceived = _swapTargetTokenForAsset(withdrawn, assetAmountOutMin);

            if (initialBalance + assetReceived >= _assets) return;

            assetNeeded -= assetReceived;
        }

        // if we still need more asset, we need to repay debt and withdraw collateral
        _repayDebtAndReleaseCollateral(debt, collateral, invested, assetNeeded);
    }

    /**
     * @notice Repays debt and releases collateral to meet asset needs.
     * @param _totalDebt The total debt owed.
     * @param _totalCollateral The total collateral supplied.
     * @param _invested The total invested in the target vault.
     * @param _assetNeeded The amount of asset tokens needed.
     */
    function _repayDebtAndReleaseCollateral(
        uint256 _totalDebt,
        uint256 _totalCollateral,
        uint256 _invested,
        uint256 _assetNeeded
    ) internal {
        // handle rounding errors when withdrawing everything
        _assetNeeded = _assetNeeded > _totalCollateral ? _totalCollateral : _assetNeeded;
        // to keep the same ltv, total debt in targetToken to be repaid has to be proportional to total asset collateral we are withdrawing
        uint256 targetTokenNeeded = _assetNeeded.mulDivUp(_totalDebt, _totalCollateral);
        targetTokenNeeded = targetTokenNeeded > _invested ? _invested : targetTokenNeeded;

        uint256 targetTokenDisinvested = 0;
        if (targetTokenNeeded != 0) targetTokenDisinvested = _disinvest(targetTokenNeeded);

        // Repay debt and withdraw collateral proportionally from each protocol
        uint256 length = protocolAdapters.length();

        for (uint256 i = 0; i < length; i++) {
            (uint256 id, address adapter) = protocolAdapters.at(i);
            uint256 collateral = IAdapter(adapter).getCollateral(address(this));

            if (collateral == 0) continue;

            uint256 debt = IAdapter(adapter).getDebt(address(this));
            uint256 toWithdraw = _assetNeeded.mulDivUp(collateral, _totalCollateral);

            if (targetTokenDisinvested != 0 && debt != 0) {
                // Keep the same LTV when withdrawing collateral
                uint256 toRepay = toWithdraw.mulDivUp(debt, collateral);

                if (toRepay > targetTokenDisinvested) {
                    toRepay = targetTokenDisinvested;
                } else {
                    targetTokenDisinvested -= toRepay;
                }

                _repay(id, toRepay);
            }

            _withdraw(id, toWithdraw);
        }
    }

    /**
     * @notice Calculates the total assets of the vault.
     * @param _float The current float balance.
     * @param _collateral The total collateral supplied.
     * @param _invested The total invested in the target vault.
     * @param _debt The total debt owed.
     * @return total The total assets of the vault.
     */
    function _calculateTotalAssets(uint256 _float, uint256 _collateral, uint256 _invested, uint256 _debt)
        internal
        view
        returns (uint256 total)
    {
        total = _float + _collateral;

        uint256 profit = _calculateProfitInTargetToken(_invested, _debt);

        if (profit != 0) {
            // account for slippage when selling targetToken profits
            total += converter().targetTokenToAsset(profit).mulWadDown(slippageTolerance);
        } else {
            total -= converter().targetTokenToAsset(_debt - _invested);
        }
    }

    /**
     * @notice Calculates the profit in target tokens.
     * @param _invested The amount invested in the target vault.
     * @param _debt The total debt owed.
     * @return The profit in target tokens.
     */
    function _calculateProfitInTargetToken(uint256 _invested, uint256 _debt) internal pure returns (uint256) {
        return _invested > _debt ? _invested - _debt : 0;
    }

    /**
     * @notice Returns the target token balance of the vault.
     * @return The balance of target tokens held by the vault.
     */
    function _targetTokenBalance() internal view returns (uint256) {
        return targetToken.balanceOf(address(this));
    }

    /**
     * @notice Returns the price converter contract casted to ISinglePairPriceConverter.
     * @return The price converter contract.
     */
    function converter() public view returns (ISinglePairPriceConverter) {
        return ISinglePairPriceConverter(address(priceConverter));
    }

    /**
     * @notice Swaps target tokens for asset tokens using the swapper contract.
     * @param _targetTokenAmount The amount of target tokens to swap.
     * @param _assetAmountOutMin The minimum amount of asset tokens to receive.
     * @return The amount of asset tokens received.
     */
    function _swapTargetTokenForAsset(uint256 _targetTokenAmount, uint256 _assetAmountOutMin)
        internal
        virtual
        returns (uint256)
    {
        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeCall(ISinglePairSwapper.swapTargetTokenForAsset, (_targetTokenAmount, _assetAmountOutMin))
        );

        return abi.decode(result, (uint256));
    }

    /**
     * @notice Swaps asset tokens for an exact amount of target tokens using the swapper contract.
     * @param _targetTokenAmountOut The exact amount of target tokens desired.
     */
    function _swapAssetForExactTargetToken(uint256 _targetTokenAmountOut) internal virtual {
        address(swapper).functionDelegateCall(
            abi.encodeCall(ISinglePairSwapper.swapAssetForExactTargetToken, (_targetTokenAmountOut))
        );
    }
}
