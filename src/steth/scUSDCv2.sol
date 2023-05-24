// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

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
    ProtocolInUse
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

/**
 * @title Sandclock USDC Vault version 2
 * @notice A vault that allows users to earn interest on their USDC deposits from leveraged WETH staking.
 * @notice The v2 vault uses multiple money markets to earn yield on USDC deposits and borrow WETH to stake.
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

    error FloatBalanceTooSmall(uint256 actual, uint256 required);

    event EmergencyExitExecuted(
        address indexed admin, uint256 wethWithdrawn, uint256 debtRepaid, uint256 collateralReleased
    );
    event Reallocated();
    event Rebalanced(uint256 totalCollateral, uint256 totalDebt, uint256 floatBalance);
    event ProfitSold(uint256 wethSold, uint256 usdcReceived);
    event EulerRewardsSold(uint256 eulerSold, uint256 usdcReceived);

    // token representing the rewards from the euler protocol
    ERC20 public constant eulerRewardsToken = ERC20(C.EULER_REWARDS_TOKEN);

    // Uniswap V3 router
    ISwapRouter public immutable swapRouter;

    // Chainlink pricefeed (USDC -> WETH)
    AggregatorV3Interface public usdcToEthPriceFeed;

    // Balancer vault for flashloans
    IVault public immutable balancerVault;

    // mapping of protocol IDs to adapters
    EnumerableMap.UintToAddressMap private protocolAdapters;

    struct ConstructorParams {
        address admin;
        address keeper;
        ERC4626 scWETH;
        ERC20 usdc;
        WETH weth;
        ISwapRouter uniswapSwapRouter;
        AggregatorV3Interface chainlinkUsdcToEthPriceFeed;
        IVault balancerVault;
    }

    constructor(ConstructorParams memory _params)
        scUSDCBase(
            _params.admin,
            _params.keeper,
            _params.usdc,
            _params.weth,
            _params.scWETH,
            "Sandclock USDC Vault v2",
            "scUSDCv2"
        )
    {
        swapRouter = _params.uniswapSwapRouter;
        usdcToEthPriceFeed = _params.chainlinkUsdcToEthPriceFeed;
        balancerVault = _params.balancerVault;

        weth.safeApprove(address(swapRouter), type(uint256).max);
        weth.safeApprove(address(scWETH), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC API
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the chainlink price feed for USDC -> WETH.
     * @param _newPriceFeed The new price feed.
     */
    function setUsdcToEthPriceFeed(AggregatorV3Interface _newPriceFeed) external {
        _onlyAdmin();

        if (address(_newPriceFeed) == address(0)) revert PriceFeedZeroAddress();

        usdcToEthPriceFeed = _newPriceFeed;
    }

    function addAdapter(IAdapter _adapter) external {
        _onlyAdmin();

        uint8 id = _adapter.id();

        if (isSupported(id)) revert ProtocolInUse(id);

        protocolAdapters.set(uint256(id), address(_adapter));

        address(_adapter).functionDelegateCall(abi.encodeWithSelector(IAdapter.setApprovals.selector));
    }

    function removeAdapter(uint8 _adapterId) external {
        _onlyAdmin();
        _isSupportedCheck(_adapterId);

        // check if protocol is being used
        if (IAdapter(protocolAdapters.get(_adapterId)).getCollateral(address(this)) > 0) {
            revert ProtocolInUse(_adapterId);
        }

        // remove approvals
        protocolAdapters.get(_adapterId).functionDelegateCall(abi.encodeWithSelector(IAdapter.revokeApprovals.selector));

        protocolAdapters.remove(_adapterId);
    }

    /**
     * @notice Rebalance the vault's positions/loans in multiple money markets.
     * @dev Called to increase or decrease the WETH debt to maintain the LTV (loan to value) and avoid liquidation.
     * @param _callData The encoded data for the calls to be made to the money markets.
     */
    function rebalance(bytes[] memory _callData) external {
        _onlyKeeper();

        _multiCall(_callData);

        // invest any weth remaining after rebalancing
        _invest();

        // enforce float to be above the minimum required
        uint256 float = usdcBalance();
        uint256 floatRequired = totalAssets().mulWadDown(floatPercentage);

        if (float < floatRequired) {
            revert FloatBalanceTooSmall(float, floatRequired);
        }

        emit Rebalanced(totalCollateral(), totalDebt(), float);
    }

    /**
     * @notice Reallocate collateral & debt between lending markets, ie move debt and collateral positions from one protocol (money market) to another.
     * @dev To move the funds between lending markets, the vault uses flashloans to repay debt and release collateral in one money market enabling it to be moved to anoter mm.
     * @param _flashLoanAmount The amount of WETH to flashloan from Balancer. Has to be at least equal to amount of WETH debt moved between lending markets.
     * @param _callData The encoded data for the calls to be made to the money markets.
     */
    function reallocate(uint256 _flashLoanAmount, bytes[] memory _callData) external {
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
     *  which can lead to withdrawals being blocked. To handle this situation, the vault can close all positions in all money markets and release all of the assets (realize all losses).
     * @param _endUsdcBalanceMin The minimum USDC balance to end with after all positions are closed.
     */
    function exitAllPositions(uint256 _endUsdcBalanceMin) external {
        _onlyAdmin();

        uint256 debt = totalDebt();

        if (wethInvested() >= debt) {
            revert VaultNotUnderwater();
        }

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
    function receiveFlashLoan(address[] memory, uint256[] memory _amounts, uint256[] memory, bytes memory _data)
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
     * @notice Sell Euler rewards (EUL) for USDC.
     * @dev Euler rewards are claimed externally, we only swap them here using 0xrouter.
     * @param _swapData The swap data for 0xrouter.
     * @param _usdcAmountOutMin The minimum amount of USDC to receive for the swap.
     */
    function sellEulerRewards(bytes calldata _swapData, uint256 _usdcAmountOutMin) external {
        _onlyKeeper();

        uint256 eulerBalance = eulerRewardsToken.balanceOf(address(this));
        uint256 initialUsdcBalance = usdcBalance();

        eulerRewardsToken.safeApprove(C.ZERO_EX_ROUTER, eulerBalance);

        C.ZERO_EX_ROUTER.functionCall(_swapData);

        uint256 usdcReceived = usdcBalance() - initialUsdcBalance;
        uint256 eulerSold = eulerBalance - eulerRewardsToken.balanceOf(address(this));

        if (usdcReceived < _usdcAmountOutMin) revert AmountReceivedBelowMin();

        eulerRewardsToken.safeApprove(C.ZERO_EX_ROUTER, 0);

        emit EulerRewardsSold(eulerSold, usdcReceived);
    }

    function supply(uint8 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _supply(_adapterId, _amount);
    }

    function borrow(uint8 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _borrow(_adapterId, _amount);
    }

    function repay(uint8 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _repay(_adapterId, _amount);
    }

    function withdraw(uint8 _adapterId, uint256 _amount) external {
        _onlyKeeperOrFlashLoan();
        _isSupportedCheck(_adapterId);

        _withdraw(_adapterId, _amount);
    }

    function invest() public {
        _onlyKeeper();

        _invest();
    }

    function disinvest(uint256 _amount) external returns (uint256) {
        _onlyKeeper();

        return _disinvest(_amount);
    }

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
     * @notice Returns the USDC fair value of the WETH amount.
     * @param _wethAmount The amount of WETH.
     */
    function getUsdcFromWeth(uint256 _wethAmount) public view returns (uint256) {
        (, int256 usdcPriceInWeth,,,) = usdcToEthPriceFeed.latestRoundData();

        return _wethAmount.divWadDown(uint256(usdcPriceInWeth) * C.WETH_USDC_DECIMALS_DIFF);
    }

    /**
     * @notice Returns the USDC balance of the vault.
     */
    function usdcBalance() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function getCollateral(uint8 _adapterId) external view returns (uint256) {
        if (!isSupported(_adapterId)) return 0;

        return IAdapter(protocolAdapters.get(_adapterId)).getCollateral(address(this));
    }

    /**
     * @notice Returns the total USDC supplied as collateral in all money markets.
     */
    function totalCollateral() public view returns (uint256 total) {
        for (uint8 i = 0; i < protocolAdapters.length(); i++) {
            (, address adapter) = protocolAdapters.at(i);
            total += IAdapter(adapter).getCollateral(address(this));
        }
    }

    function getDebt(uint8 _adapterId) external view returns (uint256) {
        if (!isSupported(_adapterId)) return 0;

        return IAdapter(protocolAdapters.get(_adapterId)).getDebt(address(this));
    }

    /**
     * @notice Returns the total WETH borrowed in all money markets.
     */
    function totalDebt() public view returns (uint256 total) {
        for (uint8 i = 0; i < protocolAdapters.length(); i++) {
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

    function _isSupportedCheck(uint8 _adapterId) internal view {
        if (!isSupported(_adapterId)) revert ProtocolNotSupported(_adapterId);
    }

    function _supply(uint8 _adapterId, uint256 _amount) internal {
        protocolAdapters.get(_adapterId).functionDelegateCall(abi.encodeWithSelector(IAdapter.supply.selector, _amount));
    }

    function _borrow(uint8 _adapterId, uint256 _amount) internal {
        protocolAdapters.get(_adapterId).functionDelegateCall(abi.encodeWithSelector(IAdapter.borrow.selector, _amount));
    }

    function _repay(uint8 _adapterId, uint256 _amount) internal {
        uint256 wethBalance = weth.balanceOf(address(this));

        _amount = _amount > wethBalance ? wethBalance : _amount;

        protocolAdapters.get(_adapterId).functionDelegateCall(abi.encodeWithSelector(IAdapter.repay.selector, _amount));
    }

    function _withdraw(uint8 _adapterId, uint256 _amount) internal {
        protocolAdapters.get(_adapterId).functionDelegateCall(
            abi.encodeWithSelector(IAdapter.withdraw.selector, _amount)
        );
    }

    function _invest() internal {
        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance > 0) scWETH.deposit(wethBalance, address(this));
    }

    function _disinvest(uint256 _wethAmount) internal returns (uint256) {
        uint256 shares = scWETH.convertToShares(_wethAmount);

        return scWETH.redeem(shares, address(this), address(this));
    }

    function _exitAllPositionsFlash(uint256 _flashLoanAmount) internal {
        for (uint8 i = 0; i < protocolAdapters.length(); i++) {
            (uint256 id, address adapter) = protocolAdapters.at(i);
            uint256 debt = IAdapter(adapter).getDebt(address(this));
            uint256 collateral = IAdapter(adapter).getCollateral(address(this));

            if (debt > 0) _repay(uint8(id), debt);
            if (collateral > 0) _withdraw(uint8(id), collateral);
        }

        asset.approve(address(swapRouter), type(uint256).max);

        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: address(asset),
            tokenOut: address(weth),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: _flashLoanAmount,
            amountInMaximum: type(uint256).max, // ignore slippage
            sqrtPriceLimitX96: 0
        });

        swapRouter.exactOutputSingle(params);

        asset.approve(address(swapRouter), 0);
    }

    function beforeWithdraw(uint256 _assets, uint256) internal override {
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
            uint256 usdcAmountOutMin = getUsdcFromWeth(withdrawn).mulWadDown(slippageTolerance);
            uint256 usdcReceived = _swapWethForUsdc(withdrawn, usdcAmountOutMin);

            if (initialBalance + usdcReceived >= _assets) return;

            usdcNeeded -= usdcReceived;
        }

        // if we still need more usdc, we need to repay debt and withdraw collateral
        _repayDebtAndReleaseCollateral(debt, collateral, invested, usdcNeeded);
    }

    function _repayDebtAndReleaseCollateral(uint256 _debt, uint256 _collateral, uint256 _invested, uint256 _usdcNeeded)
        internal
    {
        // handle rounding errors when withdrawing everything
        _usdcNeeded = _usdcNeeded > _collateral ? _collateral : _usdcNeeded;
        // to keep the same ltv, weth debt to repay has to be proportional to collateral withdrawn
        uint256 wethNeeded = _usdcNeeded.mulDivUp(_debt, _collateral);
        wethNeeded = wethNeeded > _invested ? _invested : wethNeeded;

        uint256 withdrawn = _disinvest(wethNeeded);

        // repay debt and withdraw collateral from each protocol in proportion to their collateral allocation
        for (uint8 i = 0; i < protocolAdapters.length(); i++) {
            (uint256 id, address adapter) = protocolAdapters.at(i);
            uint256 collateral = IAdapter(adapter).getCollateral(address(this));

            if (collateral == 0) continue;

            uint256 allocationPct = collateral.divWadDown(_collateral);

            _repay(uint8(id), withdrawn.mulWadDown(allocationPct));
            _withdraw(uint8(id), _usdcNeeded.mulWadDown(allocationPct));
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
            total += getUsdcFromWeth(profit).mulWadDown(slippageTolerance);
        } else {
            total -= getUsdcFromWeth(_debt - _invested);
        }
    }

    function _calculateWethProfit(uint256 _invested, uint256 _debt) internal pure returns (uint256) {
        return _invested > _debt ? _invested - _debt : 0;
    }

    function _swapWethForUsdc(uint256 _wethAmount, uint256 _usdcAmountOutMin) internal returns (uint256) {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(asset),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _wethAmount,
            amountOutMinimum: _usdcAmountOutMin,
            sqrtPriceLimitX96: 0
        });

        return swapRouter.exactInputSingle(params);
    }
}
