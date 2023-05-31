// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {
    InvalidTargetLtv,
    InvalidFlashLoanCaller,
    VaultNotUnderwater,
    NoProfitsToSell,
    FlashLoanAmountZero,
    PriceFeedZeroAddress,
    EndUsdcBalanceTooLow,
    AmountReceivedBelowMin,
    ProtocolNotSupported,
    ProtocolInUse,
    FloatBalanceTooLow
} from "../errors/scErrors.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {EnumerableMap} from "openzeppelin-contracts/utils/structs/EnumerableMap.sol";

import {Constants as C} from "../lib/Constants.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {ISwapRouter} from "../interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";
import {scUSDCBase} from "./scUSDCBase.sol";
import {IAdapter} from "./usdc-adapters/IAdapter.sol";
import {PriceConverter} from "./PriceConverter.sol";
import {Swapper} from "./Swapper.sol";

/**
 * @title Sandclock USDC Vault version 2
 * @notice A vault that allows users to earn interest on their USDC deposits from leveraged WETH staking.
 * @notice The v2 vault uses multiple lending markets to earn yield on USDC deposits and borrow WETH to stake.
 * @dev This vault uses Sandclock's leveraged WETH staking vault - scWETH.
 */
contract scUSDCv2 is scUSDCBase {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
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

    event ProtocolAdapterAdded(address indexed admin, uint8 adapterId, address adapter);
    event ProtocolAdapterRemoved(address indexed admin, uint8 adapterId);
    event EmergencyExitExecuted(
        address indexed admin, uint256 wethWithdrawn, uint256 debtRepaid, uint256 collateralReleased
    );
    event Reallocated();
    event Rebalanced(uint256 totalCollateral, uint256 totalDebt, uint256 floatBalance);
    event ProfitSold(uint256 wethSold, uint256 usdcReceived);
    event TokensSold(address token, uint256 amountSold, uint256 usdcReceived);
    event Supplied(uint8 adapterId, uint256 amount);
    event Borrowed(uint8 adapterId, uint256 amount);
    event Repaid(uint8 adapterId, uint256 amount);
    event Withdrawn(uint8 adapterId, uint256 amount);
    event Invested(uint256 wethAmount);
    event Disinvested(uint256 wethAmount);
    event RewardsClaimed(uint8 adapterId);

    // Balancer vault for flashloans
    IVault public constant balancerVault = IVault(C.BALANCER_VAULT);

    // mapping of IDs to lending protocol adapter contracts
    EnumerableMap.UintToAddressMap private protocolAdapters;

    // price converter contract
    PriceConverter public immutable priceConverter;

    // swapper contract for facilitating token swaps
    Swapper public immutable swapper;

    constructor(address _admin, address _keeper, ERC4626 _scWETH, PriceConverter _priceConverter, Swapper _swapper)
        scUSDCBase(_admin, _keeper, ERC20(C.USDC), WETH(payable(C.WETH)), _scWETH, "Sandclock USDC Vault v2", "scUSDCv2")
    {
        priceConverter = _priceConverter;
        swapper = _swapper;

        weth.safeApprove(address(scWETH), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC API
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Add a new protocol adapter to the vault.
     * @param _adapter The adapter to add.
     */
    function addAdapter(IAdapter _adapter) external {
        _onlyAdmin();

        uint8 id = _adapter.id();

        if (isSupported(id)) revert ProtocolInUse(id);

        protocolAdapters.set(uint256(id), address(_adapter));

        address(_adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.setApprovals.selector));

        emit ProtocolAdapterAdded(msg.sender, id, address(_adapter));
    }

    /**
     * @notice Remove a protocol adapter from the vault. Reverts if the adapter is in use unless _force is true.
     * @param _adapterId The ID of the adapter to remove.
     * @param _force Whether or not to force the removal of the adapter.
     */
    function removeAdapter(uint8 _adapterId, bool _force) external {
        _onlyAdmin();
        _isSupportedCheck(_adapterId);

        // check if protocol is being used
        if (!_force && IAdapter(protocolAdapters.get(_adapterId)).getCollateral(address(this)) > 0) {
            revert ProtocolInUse(_adapterId);
        }

        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.revokeApprovals.selector));

        protocolAdapters.remove(_adapterId);

        emit ProtocolAdapterRemoved(msg.sender, _adapterId);
    }

    /**
     * @notice Rebalance the vault's positions/loans in multiple lending markets.
     * @dev Called to increase or decrease the WETH debt to maintain the LTV (loan to value) and avoid liquidation.
     * @param _callData The encoded data for the calls to be made to the lending markets.
     */
    function rebalance(bytes[] calldata _callData) external {
        _onlyKeeper();

        _multiCall(_callData);

        // invest any weth remaining after rebalancing
        _invest();

        // enforce float to be above the minimum required
        uint256 float = usdcBalance();
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
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _flashLoanAmount;

        _initiateFlashLoan();
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(FlashLoanType.Reallocate, _callData));
        _finalizeFlashLoan();

        emit Reallocated();
    }

    /**
     * @notice Sells WETH profits (swaps to USDC).
     * @dev As the vault generates yield by staking WETH, the profits are in WETH.
     * @param _usdcAmountOutMin The minimum amount of USDC to receive.
     */
    function sellProfit(uint256 _usdcAmountOutMin) external {
        _onlyKeeper();

        uint256 profit = _calculateWethProfit(wethInvested(), totalDebt());

        if (profit == 0) revert NoProfitsToSell();

        uint256 withdrawn = _disinvest(profit);
        uint256 usdcReceived = _swapWethForUsdc(withdrawn, _usdcAmountOutMin);

        emit ProfitSold(withdrawn, usdcReceived);
    }

    /**
     * @notice Emergency exit to release collateral if the vault is underwater.
     * @dev In unlikely situation that the vault makes a loss on ETH staked, the total debt would be higher than ETH available to "unstake",
     *  which can lead to withdrawals being blocked. To handle this situation, the vault can close all positions in all lending markets and release all of the assets (realize all losses).
     * @param _endUsdcBalanceMin The minimum USDC balance to end with after all positions are closed.
     */
    function exitAllPositions(uint256 _endUsdcBalanceMin) external {
        _onlyAdmin();

        uint256 debt = totalDebt();

        if (wethInvested() >= debt) revert VaultNotUnderwater();

        uint256 wethBalance = scWETH.redeem(scWETH.balanceOf(address(this)), address(this), address(this));
        uint256 collateral = totalCollateral();

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = debt - wethBalance;

        _initiateFlashLoan();
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(FlashLoanType.ExitAllPositions));
        _finalizeFlashLoan();

        if (usdcBalance() < _endUsdcBalanceMin) revert EndUsdcBalanceTooLow();

        emit EmergencyExitExecuted(msg.sender, wethBalance, debt, collateral);
    }

    /**
     * @notice Handles flashloan callbacks.
     * @dev Called by Balancer's vault in 2 situations:
     * 1. When the vault is underwater and the vault needs to exit all positions.
     * 2. When the vault needs to reallocate capital between lending markets.
     * @param _amounts single elment array containing the amount of WETH being flashloaned.
     * @param _data The encoded data that was passed to the flashloan.
     */
    function receiveFlashLoan(address[] calldata, uint256[] calldata _amounts, uint256[] calldata, bytes calldata _data)
        external
    {
        _isFlashLoanInitiated();

        uint256 flashLoanAmount = _amounts[0];
        FlashLoanType flashLoanType = abi.decode(_data, (FlashLoanType));

        if (flashLoanType == FlashLoanType.ExitAllPositions) {
            _exitAllPositionsFlash(flashLoanAmount);
        } else {
            (, bytes[] memory callData) = abi.decode(_data, (FlashLoanType, bytes[]));
            _multiCall(callData);
        }

        weth.safeTransfer(address(balancerVault), flashLoanAmount);
    }

    /**
     * @notice Sell tokens awarded for using some lending market for USDC on 0x exchange.
     * @param _token The token to sell.
     * @param _amount The amount of tokens to sell.
     * @param _swapData The swap data for 0xrouter.
     * @param _usdcAmountOutMin The minimum amount of USDC to receive for the swap.
     */
    function sellTokens(ERC20 _token, uint256 _amount, bytes calldata _swapData, uint256 _usdcAmountOutMin) external {
        _onlyKeeper();

        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(Swapper.zeroExSwap.selector, _token, asset, _amount, _usdcAmountOutMin, _swapData)
        );

        emit TokensSold(address(_token), _amount, abi.decode(result, (uint256)));
    }

    /**
     * @notice Supply USDC assets to a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _amount The amount of USDC to supply.
     */
    function supply(uint8 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _supply(_adapterId, _amount);
    }

    /**
     * @notice Borrow WETH from a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _amount The amount of WETH to borrow.
     */
    function borrow(uint8 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _borrow(_adapterId, _amount);
    }

    /**
     * @notice Repay WETH to a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _amount The amount of WETH to repay.
     */
    function repay(uint8 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _repay(_adapterId, _amount);
    }

    /**
     * @notice Withdraw USDC assets from a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _amount The amount of USDC to withdraw.
     */
    function withdraw(uint8 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _withdraw(_adapterId, _amount);
    }

    /**
     * @notice Claim rewards from a lending market.
     * @param _adapterId The ID of the lending market adapter.
     * @param _callData The encoded data for the claimRewards function.
     */
    function claimRewards(uint8 _adapterId, bytes calldata _callData) external {
        _onlyKeeper();
        _isSupportedCheck(_adapterId);
        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.claimRewards.selector, _callData));

        emit RewardsClaimed(_adapterId);
    }

    /**
     * @notice Withdraw WETH from the staking vault (scWETH).
     * @param _amount The amount of WETH to withdraw.
     */
    function disinvest(uint256 _amount) external {
        _onlyKeeper();

        _disinvest(_amount);
    }

    /**
     * @notice Check if a lending market adapter is supported/used.
     * @param _adapterId The ID of the lending market adapter.
     */
    function isSupported(uint8 _adapterId) public view returns (bool) {
        return protocolAdapters.contains(_adapterId);
    }

    /**
     * @notice total claimable assets of the vault in USDC.
     */
    function totalAssets() public view override returns (uint256) {
        return _calculateTotalAssets(usdcBalance(), totalCollateral(), wethInvested(), totalDebt());
    }

    /**
     * @notice Returns the USDC balance of the vault.
     */
    function usdcBalance() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Returns the USDC supplied as collateral in a lending market.
     * @param _adapterId The ID of the lending market adapter.
     */
    function getCollateral(uint8 _adapterId) external view returns (uint256) {
        if (!isSupported(_adapterId)) return 0;

        return IAdapter(protocolAdapters.get(_adapterId)).getCollateral(address(this));
    }

    /**
     * @notice Returns the total USDC supplied as collateral in all lending markets.
     */
    function totalCollateral() public view returns (uint256 total) {
        uint256 length = protocolAdapters.length();

        for (uint8 i = 0; i < length; i++) {
            (, address adapter) = protocolAdapters.at(i);
            total += IAdapter(adapter).getCollateral(address(this));
        }
    }

    /**
     * @notice Returns the WETH borrowed from a lending market.
     * @param _adapterId The ID of the lending market adapter.
     */
    function getDebt(uint8 _adapterId) external view returns (uint256) {
        if (!isSupported(_adapterId)) return 0;

        return IAdapter(protocolAdapters.get(_adapterId)).getDebt(address(this));
    }

    /**
     * @notice Returns the total WETH borrowed in all lending markets.
     */
    function totalDebt() public view returns (uint256 total) {
        uint256 length = protocolAdapters.length();

        for (uint8 i = 0; i < length; i++) {
            (, address adapter) = protocolAdapters.at(i);
            total += IAdapter(adapter).getDebt(address(this));
        }
    }

    /**
     * @notice Returns the amount of WETH invested (staked) in the leveraged WETH vault.
     */
    function wethInvested() public view returns (uint256) {
        return scWETH.convertToAssets(scWETH.balanceOf(address(this)));
    }

    /**
     * @notice Returns the amount of profit (in WETH) made by the vault.
     * @dev The profit is calculated as the difference between the current WETH staked and the WETH owed.
     */
    function getProfit() public view returns (uint256) {
        return _calculateWethProfit(wethInvested(), totalDebt());
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL API
    //////////////////////////////////////////////////////////////*/

    function _multiCall(bytes[] memory _callData) internal {
        for (uint8 i = 0; i < _callData.length; i++) {
            address(this).functionDelegateCall(_callData[i]);
        }
    }

    function _adapterDelegateCall(uint8 _adapterId, bytes memory _data) internal {
        protocolAdapters.get(_adapterId).functionDelegateCall(_data);
    }

    function _isSupportedCheck(uint8 _adapterId) internal view {
        if (!isSupported(_adapterId)) revert ProtocolNotSupported(_adapterId);
    }

    function _supply(uint8 _adapterId, uint256 _amount) internal {
        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.supply.selector, _amount));

        emit Supplied(_adapterId, _amount);
    }

    function _borrow(uint8 _adapterId, uint256 _amount) internal {
        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.borrow.selector, _amount));

        emit Borrowed(_adapterId, _amount);
    }

    function _repay(uint8 _adapterId, uint256 _amount) internal {
        uint256 wethBalance = weth.balanceOf(address(this));

        _amount = _amount > wethBalance ? wethBalance : _amount;

        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.repay.selector, _amount));

        emit Repaid(_adapterId, _amount);
    }

    function _withdraw(uint8 _adapterId, uint256 _amount) internal {
        _adapterDelegateCall(_adapterId, abi.encodeWithSelector(IAdapter.withdraw.selector, _amount));

        emit Withdrawn(_adapterId, _amount);
    }

    function _invest() internal {
        uint256 wethBalance = weth.balanceOf(address(this));

        if (wethBalance > 0) {
            scWETH.deposit(wethBalance, address(this));

            emit Invested(wethBalance);
        }
    }

    function _disinvest(uint256 _wethAmount) internal returns (uint256) {
        uint256 shares = scWETH.convertToShares(_wethAmount);

        uint256 amount = scWETH.redeem(shares, address(this), address(this));

        emit Disinvested(amount);

        return amount;
    }

    function _exitAllPositionsFlash(uint256 _flashLoanAmount) internal {
        uint256 length = protocolAdapters.length();

        for (uint8 i = 0; i < length; i++) {
            (uint256 id, address adapter) = protocolAdapters.at(i);
            uint256 debt = IAdapter(adapter).getDebt(address(this));
            uint256 collateral = IAdapter(adapter).getCollateral(address(this));

            if (debt > 0) _repay(uint8(id), debt);
            if (collateral > 0) _withdraw(uint8(id), collateral);
        }

        _swapUsdcForExactWeth(_flashLoanAmount);
    }

    function beforeWithdraw(uint256 _assets, uint256) internal override {
        // here we need to make sure that the vault has enough assets to cover the withdrawal
        // the idea is to keep the same ltv after the withdrawal as before on every protocol
        uint256 initialBalance = usdcBalance();
        if (initialBalance >= _assets) return;

        uint256 collateral = totalCollateral();
        uint256 debt = totalDebt();
        uint256 invested = wethInvested();
        uint256 total = _calculateTotalAssets(initialBalance, collateral, invested, debt);
        uint256 profit = _calculateWethProfit(invested, debt);
        uint256 floatRequired = total > _assets ? (total - _assets).mulWadUp(floatPercentage) : 0;
        uint256 usdcNeeded = _assets + floatRequired - initialBalance;

        // first try to sell profits to cover withdrawal amount
        if (profit != 0) {
            uint256 withdrawn = _disinvest(profit);
            uint256 usdcAmountOutMin = priceConverter.getUsdcFromWeth(withdrawn).mulWadDown(slippageTolerance);
            uint256 usdcReceived = _swapWethForUsdc(withdrawn, usdcAmountOutMin);

            if (initialBalance + usdcReceived >= _assets) return;

            usdcNeeded -= usdcReceived;
        }

        // if we still need more usdc, we need to repay debt and withdraw collateral
        _repayDebtAndReleaseCollateral(debt, collateral, invested, usdcNeeded);
    }

    function _repayDebtAndReleaseCollateral(
        uint256 _totalDebt,
        uint256 _totalCollateral,
        uint256 _invested,
        uint256 _usdcNeeded
    ) internal {
        // handle rounding errors when withdrawing everything
        _usdcNeeded = _usdcNeeded > _totalCollateral ? _totalCollateral : _usdcNeeded;
        // to keep the same ltv, total debt in weth to be repaid has to be proportional to total usdc collateral we are withdrawing
        uint256 wethNeeded = _usdcNeeded.mulDivUp(_totalDebt, _totalCollateral);
        wethNeeded = wethNeeded > _invested ? _invested : wethNeeded;

        uint256 wethDisinvested = 0;
        if (wethNeeded != 0) wethDisinvested = _disinvest(wethNeeded);

        // repay debt and withdraw collateral from each protocol in proportion to usdc supplied
        uint256 length = protocolAdapters.length();

        for (uint8 i = 0; i < length; i++) {
            (uint256 id, address adapter) = protocolAdapters.at(i);
            uint256 collateral = IAdapter(adapter).getCollateral(address(this));

            if (collateral == 0) continue;

            uint256 debt = IAdapter(adapter).getDebt(address(this));
            uint256 toWithdraw = _usdcNeeded.mulDivUp(collateral, _totalCollateral);

            if (wethDisinvested != 0 && debt != 0) {
                // keep the same ltv when withdrawing usdc supplied from each protocol
                uint256 toRepay = toWithdraw.mulDivUp(debt, collateral);

                if (toRepay > wethDisinvested) {
                    toRepay = wethDisinvested;
                } else {
                    wethDisinvested -= toRepay;
                }

                _repay(uint8(id), toRepay);
            }

            _withdraw(uint8(id), toWithdraw);
        }
    }

    function _calculateTotalAssets(uint256 _float, uint256 _collateral, uint256 _invested, uint256 _debt)
        internal
        view
        returns (uint256 total)
    {
        total = _float + _collateral;

        uint256 profit = _calculateWethProfit(_invested, _debt);

        if (profit != 0) {
            // account for slippage when selling weth profits
            total += priceConverter.getUsdcFromWeth(profit).mulWadDown(slippageTolerance);
        } else {
            total -= priceConverter.getUsdcFromWeth(_debt - _invested);
        }
    }

    function _calculateWethProfit(uint256 _invested, uint256 _debt) internal pure returns (uint256) {
        return _invested > _debt ? _invested - _debt : 0;
    }

    function _swapWethForUsdc(uint256 _wethAmount, uint256 _usdcAmountOutMin) internal returns (uint256) {
        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                Swapper.uniswapSwapExactInput.selector, weth, asset, _wethAmount, _usdcAmountOutMin
            )
        );

        return abi.decode(result, (uint256));
    }

    function _swapUsdcForExactWeth(uint256 _wethAmountOut) internal {
        address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                Swapper.uniswapSwapExactOutput.selector,
                asset,
                weth,
                _wethAmountOut,
                type(uint256).max // ignore slippage
            )
        );
    }
}
