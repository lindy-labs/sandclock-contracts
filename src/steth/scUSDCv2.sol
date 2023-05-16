// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {
    InvalidTargetLtv,
    InvalidSlippageTolerance,
    InvalidFloatPercentage,
    InvalidFlashLoanCaller,
    VaultNotUnderwater,
    NoProfitsToSell,
    FlashLoanAmountZero,
    PriceFeedZeroAddress,
    EndUsdcBalanceTooLow
} from "../errors/scErrors.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {Constants as C} from "../lib/Constants.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {ISwapRouter} from "../interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";
import {scUSDCBase} from "./scUSDCBase.sol";
import {UsdcWethLendingManager} from "./UsdcWethLendingManager.sol";

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

    /**
     * @notice Enum indicating the purpose of a flashloan.
     */
    enum FlashLoanType {
        Reallocate,
        ExitAllPositions
    }

    /**
     * @notice Struct containing parameters for moving funds between money markets.
     */
    struct ReallocationParams {
        UsdcWethLendingManager.Protocol protocolId;
        bool isDownsize;
        uint256 collateralAmount;
        uint256 debtAmount;
    }

    /**
     * @notice Struct containing parameters for rebalancing the loans taken on multiple money markets (protocols).
     */
    struct RebalanceParams {
        UsdcWethLendingManager.Protocol protocolId;
        uint256 supplyAmount;
        bool leverageUp;
        uint256 wethAmount;
    }

    error LtvAboveMaxAllowed(UsdcWethLendingManager.Protocol protocolId);
    error FloatBalanceTooSmall(uint256 actual, uint256 required);

    event EmergencyExitExecuted(
        address indexed admin, uint256 wethWithdrawn, uint256 debtRepaid, uint256 collateralReleased
    );
    event Reallocated(UsdcWethLendingManager.Protocol protocolId, bool isDownsize, uint256 collateral, uint256 debt);
    event Rebalanced(UsdcWethLendingManager.Protocol protocolId, uint256 supplied, bool leverageUp, uint256 debt);
    event ProfitSold(uint256 wethSold, uint256 usdcReceived);
    event EulerRewardsSold(uint256 eulerSold, uint256 usdcReceived);

    // Uniswap V3 router
    ISwapRouter public immutable swapRouter;

    // Chainlink pricefeed (USDC -> WETH)
    AggregatorV3Interface public usdcToEthPriceFeed;

    // Balancer vault for flashloans
    IVault public immutable balancerVault;

    // lending manager contract used to interact with different money markets
    UsdcWethLendingManager public immutable lendingManager;

    struct ConstructorParams {
        address admin;
        address keeper;
        ERC4626 scWETH;
        ERC20 usdc;
        WETH weth;
        UsdcWethLendingManager lendingManager;
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
        lendingManager = _params.lendingManager;
        swapRouter = _params.uniswapSwapRouter;
        usdcToEthPriceFeed = _params.chainlinkUsdcToEthPriceFeed;
        balancerVault = _params.balancerVault;

        weth.safeApprove(address(swapRouter), type(uint256).max);
        weth.safeApprove(address(scWETH), type(uint256).max);

        asset.safeApprove(address(lendingManager.aaveV2Pool()), type(uint256).max);
        weth.safeApprove(address(lendingManager.aaveV2Pool()), type(uint256).max);

        asset.safeApprove(address(lendingManager.aaveV3Pool()), type(uint256).max);
        weth.safeApprove(address(lendingManager.aaveV3Pool()), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC API
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Enable use of the Euler Protocol. Disabled by default.
     */
    function enableEuler() external {
        _onlyAdmin();

        asset.safeApprove(lendingManager.eulerProtocol(), type(uint256).max);
        weth.safeApprove(lendingManager.eulerProtocol(), type(uint256).max);
        lendingManager.eulerMarkets().enterMarket(0, address(asset));
    }

    /**
     * @notice Set the chainlink price feed for USDC -> WETH.
     * @param _newPriceFeed The new price feed.
     */
    function setUsdcToEthPriceFeed(AggregatorV3Interface _newPriceFeed) external {
        _onlyAdmin();

        if (address(_newPriceFeed) == address(0)) revert PriceFeedZeroAddress();

        usdcToEthPriceFeed = _newPriceFeed;
    }

    /**
     * @notice Rebalance the vault's positions/loans in multiple money markets.
     * @dev Called to increase or decrease the WETH debt to maintain the LTV (loan to value) and avoid liquidation.
     */
    function rebalance(RebalanceParams[] calldata _params) external {
        _onlyKeeper();

        for (uint8 i = 0; i < _params.length; i++) {
            // respect new deposits
            if (_params[i].supplyAmount != 0) {
                _supply(uint8(_params[i].protocolId), _params[i].supplyAmount);
            }

            // borrow and invest or disinvest and repay
            if (_params[i].leverageUp) {
                _borrow(uint8(_params[i].protocolId), _params[i].wethAmount);
                scWETH.deposit(_params[i].wethAmount, address(this));
            } else {
                uint256 withdrawn = _disinvest(_params[i].wethAmount);
                _repay(uint8(_params[i].protocolId), withdrawn);
            }

            emit Rebalanced(
                _params[i].protocolId, _params[i].supplyAmount, _params[i].leverageUp, _params[i].wethAmount
            );
        }

        // enforce float to be above the minimum required
        uint256 float = usdcBalance();
        uint256 floatRequired = totalAssets().mulWadDown(floatPercentage);

        if (float < floatRequired) {
            revert FloatBalanceTooSmall(float, floatRequired);
        }
    }

    /**
     * @notice Reallocate collateral & debt between lending markets, ie move debt and collateral positions from one protocol (money market) to another.
     * @dev To move the funds between lending markets, the vault uses flashloans to repay debt and release collateral in one money market enabling it to be moved to anoter mm.
     * @param _params The reallocation parameters. Markets where positions are downsized must be listed first because collateral has to be relased before it is reallocated.
     * @param _flashLoanAmount The amount of WETH to flashloan from Balancer. Has to be at least equal to amount of WETH debt moved between lending markets.
     */
    function reallocate(ReallocationParams[] calldata _params, uint256 _flashLoanAmount) external {
        _onlyKeeper();

        if (_flashLoanAmount == 0) revert FlashLoanAmountZero();

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _flashLoanAmount;

        _initiateFlashLoan();
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(FlashLoanType.Reallocate, _params));
        _finalizeFlashLoan();
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

        if (msg.sender != address(balancerVault)) revert InvalidFlashLoanCaller();

        uint256 flashLoanAmount = _amounts[0];
        FlashLoanType flashLoanType = abi.decode(_data, (FlashLoanType));

        if (flashLoanType == FlashLoanType.ExitAllPositions) {
            _exitAllPositionsFlash(flashLoanAmount);
        } else {
            (, ReallocationParams[] memory params) = abi.decode(_data, (FlashLoanType, ReallocationParams[]));
            _reallocateFlash(params);
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

        (bool success, bytes memory result) = address(lendingManager).delegatecall(
            abi.encodeWithSelector(UsdcWethLendingManager.sellEulerRewards.selector, _swapData, _usdcAmountOutMin)
        );
        if (!success) revert(string(result));
        (uint256 eulerSold, uint256 usdcReceived) = abi.decode(result, (uint256, uint256));

        emit EulerRewardsSold(eulerSold, usdcReceived);
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
     * @notice Returns the WETH fair value of the USDC amount.
     * @param _usdcAmount The amount of USDC.
     */
    function getWethFromUsdc(uint256 _usdcAmount) public view returns (uint256) {
        (, int256 usdcPriceInWeth,,,) = usdcToEthPriceFeed.latestRoundData();

        return (_usdcAmount * C.WETH_USDC_DECIMALS_DIFF).mulWadDown(uint256(usdcPriceInWeth));
    }

    /**
     * @notice Returns the USDC balance of the vault.
     */
    function usdcBalance() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Returns the total USDC supplied as collateral in all money markets.
     */
    function totalCollateral() public view returns (uint256 total) {
        for (uint8 i = 0; i <= uint8(type(UsdcWethLendingManager.Protocol).max); i++) {
            if (_isEulerAndDisabled(UsdcWethLendingManager.Protocol(i))) continue;

            total += lendingManager.getCollateral(UsdcWethLendingManager.Protocol(i), address(this));
        }
    }

    /**
     * @notice Returns the total WETH borrowed in all money markets.
     */
    function totalDebt() public view returns (uint256 total) {
        for (uint8 i = 0; i <= uint8(type(UsdcWethLendingManager.Protocol).max); i++) {
            if (_isEulerAndDisabled(UsdcWethLendingManager.Protocol(i))) continue;

            total += lendingManager.getDebt(UsdcWethLendingManager.Protocol(i), address(this));
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

    function _supply(uint8 _protocolId, uint256 _amount) internal {
        _lendingManagerDelegateCall(UsdcWethLendingManager.supply.selector, _protocolId, _amount);
    }

    function _borrow(uint8 _protocolId, uint256 _amount) internal {
        _lendingManagerDelegateCall(UsdcWethLendingManager.borrow.selector, _protocolId, _amount);
    }

    function _repay(uint8 _protocolId, uint256 _amount) internal {
        _lendingManagerDelegateCall(UsdcWethLendingManager.repay.selector, _protocolId, _amount);
    }

    function _withdraw(uint8 _protocolId, uint256 _amount) internal {
        _lendingManagerDelegateCall(UsdcWethLendingManager.withdraw.selector, _protocolId, _amount);
    }

    /// @dev Need to use "delegatecall" to interact with lending protocols through the lending manager contract.
    function _lendingManagerDelegateCall(bytes4 _selector, uint8 _protocolId, uint256 _amount) internal {
        (bool success, bytes memory result) =
            address(lendingManager).delegatecall(abi.encodeWithSelector(_selector, _protocolId, _amount));

        if (!success) revert(string(result));
    }

    function _reallocateFlash(ReallocationParams[] memory _params) internal {
        for (uint8 i = 0; i < _params.length; i++) {
            if (_params[i].isDownsize) {
                _repay(uint8(_params[i].protocolId), _params[i].debtAmount);
                _withdraw(uint8(_params[i].protocolId), _params[i].collateralAmount);
            } else {
                _supply(uint8(_params[i].protocolId), _params[i].collateralAmount);
                _borrow(uint8(_params[i].protocolId), _params[i].debtAmount);
            }

            emit Reallocated(
                _params[i].protocolId, _params[i].isDownsize, _params[i].collateralAmount, _params[i].debtAmount
            );
        }
    }

    function _exitAllPositionsFlash(uint256 _flashLoanAmount) internal {
        for (uint8 i = 0; i <= uint256(type(UsdcWethLendingManager.Protocol).max); i++) {
            if (_isEulerAndDisabled(UsdcWethLendingManager.Protocol(i))) continue;

            uint256 debt = lendingManager.getDebt(UsdcWethLendingManager.Protocol(i), address(this));
            uint256 collateral = lendingManager.getCollateral(UsdcWethLendingManager.Protocol(i), address(this));

            if (debt > 0) {
                _repay(i, debt);
                _withdraw(i, collateral);
            }
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
        for (uint8 i = 0; i <= uint8(type(UsdcWethLendingManager.Protocol).max); i++) {
            if (_isEulerAndDisabled(UsdcWethLendingManager.Protocol(i))) continue;

            uint256 collateral = lendingManager.getCollateral(UsdcWethLendingManager.Protocol(i), address(this));

            if (collateral == 0) continue;

            uint256 allocationPct = collateral.divWadDown(_collateral);

            _repay(i, withdrawn.mulWadUp(allocationPct));
            _withdraw(i, _usdcNeeded.mulWadUp(allocationPct));
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

    function _disinvest(uint256 _wethAmount) internal returns (uint256) {
        uint256 shares = scWETH.convertToShares(_wethAmount);

        return scWETH.redeem(shares, address(this), address(this));
    }

    function _isEulerAndDisabled(UsdcWethLendingManager.Protocol _protocolId) internal view returns (bool) {
        return _protocolId == UsdcWethLendingManager.Protocol.EULER
            && asset.allowance(address(this), address(lendingManager.eulerProtocol())) == 0;
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
