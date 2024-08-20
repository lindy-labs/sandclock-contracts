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
import {Swapper} from "./Swapper.sol";
import {PriceConverter} from "./PriceConverter.sol";
import {ISinglePairPriceConverter} from "./priceConverter/IPriceConverter.sol";

/**
 * @dev A separate swapper and priceConverter contract for each vault
 */
abstract contract scCrossAssetYieldVault is BaseV2Vault {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;
    using Address for address;
    using EnumerableMap for EnumerableMap.UintToAddressMap;

    /**
     * @notice Enum indicating the purpose of a flashloan.
     */
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

    ERC4626 public immutable targetVault;
    ERC20 public immutable targetToken;

    constructor(
        address _admin,
        address _keeper,
        ERC20 _asset,
        ERC4626 _targetVault,
        ISinglePairPriceConverter _priceConverter,
        Swapper _swapper,
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
     * @notice Rebalance the vault's positions/loans in multiple lending markets.
     * @dev Called to increase or decrease the WETH debt to maintain the LTV (loan to value) and avoid liquidation.
     * @param _callData The encoded data for the calls to be made to the lending markets.
     */
    function rebalance(bytes[] calldata _callData) external {
        _onlyKeeper();

        _multiCall(_callData);

        // invest any targetToken remaining after rebalancing
        _invest();

        // enforce float to be above the minimum required
        uint256 float = assetBalance();
        uint256 floatRequired = totalAssets().mulWadDown(floatPercentage);

        if (float < floatRequired) {
            revert FloatBalanceTooLow(float, floatRequired);
        }

        emit Rebalanced(totalCollateral(), totalDebt(), float);
    }

    /**
     * @notice Reallocate collateral & debt between lending markets, ie move debt and collateral positions from one lending market to another.
     * @dev To move the funds between lending markets, the vault uses flashloans to repay debt and release collateral in one lending market enabling it to be moved to anoter mm.
     * @param _flashLoanAmount The amount of WETH to flashloan from Balancer. Has to be at least equal to amount of WETH debt moved between lending markets.
     * @param _callData The encoded data for the calls to be made to the lending markets.
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
     * @notice Sells WETH profits (swaps to asset).
     * @dev As the vault generates yield by staking WETH, the profits are in WETH.
     * @param _assetAmountOutMin The minimum amount of asset to receive.
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
     * @notice Emergency exit to disinvest everything, repay all debt and withdraw all collateral to the vault.
     * @dev In unlikely situation that the vault makes a loss on ETH staked, the total debt would be higher than ETH available to "unstake",
     *  which can lead to withdrawals being blocked. To handle this situation, the vault can close all positions in all lending markets and release all of the assets (realize all losses).
     * @param _endAssetBalanceMin The minimum asset balance of the vault at the end of execution (after all positions are closed).
     */
    function exitAllPositions(uint256 _endAssetBalanceMin) external {
        _onlyKeeper();

        uint256 collateral = totalCollateral();
        uint256 debt = totalDebt();
        uint256 targetTokenBalance =
            targetVault.redeem(targetVault.balanceOf(address(this)), address(this), address(this));

        if (debt > targetTokenBalance) {
            // not enough WETH to repay all debt, flashloan the difference
            address[] memory tokens = new address[](1);
            tokens[0] = address(targetToken);

            uint256[] memory amounts = new uint256[](1);
            amounts[0] = debt - targetTokenBalance;

            _initiateFlashLoan();
            balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(FlashLoanType.ExitAllPositions));
            _finalizeFlashLoan();
        } else {
            _repayAllDebtAndWithdrawCollateral();

            // if some WETH remains after repaying all debt, swap it to asset
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
     * @param _amounts single elment array containing the amount of WETH being flashloaned.
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
     * @notice Supply asset assets to a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _amount The amount of asset to supply.
     */
    function supply(uint256 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _supply(_adapterId, _amount);
    }

    /**
     * @notice Borrow WETH from a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _amount The amount of WETH to borrow.
     */
    function borrow(uint256 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _borrow(_adapterId, _amount);
    }

    /**
     * @notice Repay WETH to a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _amount The amount of WETH to repay.
     */
    function repay(uint256 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _repay(_adapterId, _amount);
    }

    /**
     * @notice Withdraw asset assets from a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _amount The amount of asset to withdraw.
     */
    function withdraw(uint256 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _withdraw(_adapterId, _amount);
    }

    /**
     * @notice Withdraw WETH from the staking vault (targetVault).
     * @param _amount The amount of WETH to withdraw.
     */
    function disinvest(uint256 _amount) external {
        _onlyKeeper();

        _disinvest(_amount);
    }

    /**
     * @notice total claimable assets of the vault in asset.
     */
    function totalAssets() public view override returns (uint256) {
        return _calculateTotalAssets(assetBalance(), totalCollateral(), targetTokenInvestedAmount(), totalDebt());
    }

    /**
     * @notice Returns the asset balance of the vault.
     */
    function assetBalance() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Returns the asset supplied as collateral in a lending market.
     * @param _adapterId The ID of the lending market adapter.
     */
    function getCollateral(uint256 _adapterId) external view returns (uint256) {
        if (!isSupported(_adapterId)) return 0;

        return IAdapter(protocolAdapters.get(_adapterId)).getCollateral(address(this));
    }

    /**
     * @notice Returns the total asset supplied as collateral in all lending markets.
     */
    function totalCollateral() public view returns (uint256 total) {
        uint256 length = protocolAdapters.length();

        for (uint256 i = 0; i < length; i++) {
            (, address adapter) = protocolAdapters.at(i);
            total += IAdapter(adapter).getCollateral(address(this));
        }
    }

    /**
     * @notice Returns the WETH borrowed from a lending market.
     * @param _adapterId The ID of the lending market adapter.
     */
    function getDebt(uint256 _adapterId) external view returns (uint256) {
        if (!isSupported(_adapterId)) return 0;

        return IAdapter(protocolAdapters.get(_adapterId)).getDebt(address(this));
    }

    /**
     * @notice Returns the total WETH borrowed in all lending markets.
     */
    function totalDebt() public view returns (uint256 total) {
        uint256 length = protocolAdapters.length();

        for (uint256 i = 0; i < length; i++) {
            (, address adapter) = protocolAdapters.at(i);
            total += IAdapter(adapter).getDebt(address(this));
        }
    }

    /**
     * @notice Returns the amount of WETH invested (staked) in the leveraged WETH vault.
     */
    function targetTokenInvestedAmount() public view returns (uint256) {
        return targetVault.convertToAssets(targetVault.balanceOf(address(this)));
    }

    /**
     * @notice Returns the amount of profit (in WETH) made by the vault.
     * @dev The profit is calculated as the difference between the current WETH staked and the WETH owed.
     */
    function getProfit() public view returns (uint256) {
        return _calculateProfitInTargetToken(targetTokenInvestedAmount(), totalDebt());
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL API
    //////////////////////////////////////////////////////////////*/

    function _supply(uint256 _adapterId, uint256 _amount) internal {
        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.supply.selector, _amount));

        emit Supplied(_adapterId, _amount);
    }

    function _borrow(uint256 _adapterId, uint256 _amount) internal {
        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.borrow.selector, _amount));

        emit Borrowed(_adapterId, _amount);
    }

    function _repay(uint256 _adapterId, uint256 _amount) internal {
        uint256 targetTokenBalance = _targetTokenBalance();

        _amount = _amount > targetTokenBalance ? targetTokenBalance : _amount;

        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.repay.selector, _amount));

        emit Repaid(_adapterId, _amount);
    }

    function _withdraw(uint256 _adapterId, uint256 _amount) internal {
        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.withdraw.selector, _amount));

        emit Withdrawn(_adapterId, _amount);
    }

    function _invest() internal {
        uint256 targetTokenBalance = _targetTokenBalance();

        if (targetTokenBalance > 0) {
            targetVault.deposit(targetTokenBalance, address(this));

            emit Invested(targetTokenBalance);
        }
    }

    function _disinvest(uint256 _targetTokenAmount) internal returns (uint256) {
        uint256 shares = targetVault.convertToShares(_targetTokenAmount);

        uint256 amount = targetVault.redeem(shares, address(this), address(this));

        emit Disinvested(amount);

        return amount;
    }

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

    function beforeWithdraw(uint256 _assets, uint256) internal override {
        // here we need to make sure that the vault has enough assets to cover the withdrawal
        // the idea is to keep the same ltv after the withdrawal as before on every protocol
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
            uint256 assetAmountOutMin = converter().tokenToBaseAsset(withdrawn).mulWadDown(slippageTolerance);
            uint256 assetReceived = _swapTargetTokenForAsset(withdrawn, assetAmountOutMin);

            if (initialBalance + assetReceived >= _assets) return;

            assetNeeded -= assetReceived;
        }

        // if we still need more asset, we need to repay debt and withdraw collateral
        _repayDebtAndReleaseCollateral(debt, collateral, invested, assetNeeded);
    }

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

        // repay debt and withdraw collateral from each protocol in proportion to asset supplied
        uint256 length = protocolAdapters.length();

        for (uint256 i = 0; i < length; i++) {
            (uint256 id, address adapter) = protocolAdapters.at(i);
            uint256 collateral = IAdapter(adapter).getCollateral(address(this));

            if (collateral == 0) continue;

            uint256 debt = IAdapter(adapter).getDebt(address(this));
            uint256 toWithdraw = _assetNeeded.mulDivUp(collateral, _totalCollateral);

            if (targetTokenDisinvested != 0 && debt != 0) {
                // keep the same ltv when withdrawing asset supplied from each protocol
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

    function _calculateTotalAssets(uint256 _float, uint256 _collateral, uint256 _invested, uint256 _debt)
        internal
        view
        returns (uint256 total)
    {
        total = _float + _collateral;

        uint256 profit = _calculateProfitInTargetToken(_invested, _debt);

        if (profit != 0) {
            // account for slippage when selling targetToken profits
            total += converter().tokenToBaseAsset(profit).mulWadDown(slippageTolerance);
        } else {
            total -= converter().tokenToBaseAsset(_debt - _invested);
        }
    }

    function _calculateProfitInTargetToken(uint256 _invested, uint256 _debt) internal pure returns (uint256) {
        return _invested > _debt ? _invested - _debt : 0;
    }

    function _targetTokenBalance() internal view returns (uint256) {
        return targetToken.balanceOf(address(this));
    }

    function converter() public view returns (ISinglePairPriceConverter) {
        return ISinglePairPriceConverter(address(priceConverter));
    }

    function _swapTargetTokenForAsset(uint256 _targetTokenAmount, uint256 _assetAmountOutMin)
        internal
        virtual
        returns (uint256);

    function _swapAssetForExactTargetToken(uint256 _targetTokenAmountOut) internal virtual;
}
