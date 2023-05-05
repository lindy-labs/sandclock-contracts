// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {
    InvalidTargetLtv,
    InvalidSlippageTolerance,
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
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";
import {IEulerMarkets, IEulerEToken, IEulerDToken} from "lib/euler-interfaces/contracts/IEuler.sol";

import {Constants as C} from "../lib/Constants.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {ISwapRouter} from "../interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";
import {sc4626} from "../sc4626.sol";
import {UsdcWethLendingManager} from "./UsdcWethLendingManager.sol";

// TODO: add function for harvesting EULER reward tokens
// TODO: update documentation
/**
 * @title Sandclock USDC Vault
 * @notice A vault that allows users to earn interest on their USDC deposits from leveraged WETH staking.
 * @dev This vault uses Sandclock's leveraged WETH staking vault - scWETH.
 */
contract scUSDCv2 is sc4626, UsdcWethLendingManager, IFlashLoanRecipient {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    using FixedPointMathLib for uint256;

    enum FlashLoanType {
        Reallocate,
        ExitAllPositions
    }

    struct ReallocationParams {
        Protocol protocolId;
        bool isDownsize;
        uint256 collateralAmount;
        uint256 debtAmount;
    }

    struct RebalanceParams {
        Protocol protocolId;
        uint256 supplyAmount;
        bool leverageUp;
        uint256 wethAmount;
    }

    error LtvAboveMaxAllowed(Protocol protocolId);
    error FloatBalanceTooSmall(uint256 actual, uint256 required);

    event NewTargetLtvApplied(address indexed admin, uint256 newTargetLtv);
    event SlippageToleranceUpdated(address indexed admin, uint256 newSlippageTolerance);
    event EmergencyExitExecuted(
        address indexed admin, uint256 wethWithdrawn, uint256 debtRepaid, uint256 collateralReleased
    );
    event Reallocated(Protocol protocolId, bool isDownsize, uint256 collateral, uint256 debt);
    event Rebalanced(Protocol protocolId, uint256 supplied, bool leverageUp, uint256 debt);
    event ProfitSold(uint256 wethSold, uint256 usdcReceived);

    // Uniswap V3 router
    ISwapRouter public immutable swapRouter;

    // Chainlink pricefeed (USDC -> WETH)
    AggregatorV3Interface public usdcToEthPriceFeed;

    // Balancer vault for flashloans
    IVault public immutable balancerVault;

    // max slippage for swapping WETH -> USDC
    uint256 public slippageTolerance = 0.99e18; // 1% default

    // leveraged (w)eth vault
    ERC4626 public immutable scWETH;

    struct ConstructorParams {
        address admin;
        address keeper;
        ERC4626 scWETH;
        ERC20 usdc;
        WETH weth;
        AaveV3 aaveV3;
        AaveV2 aaveV2;
        Euler euler;
        ISwapRouter uniswapSwapRouter;
        AggregatorV3Interface chainlinkUsdcToEthPriceFeed;
        IVault balancerVault;
    }

    constructor(ConstructorParams memory _params)
        sc4626(_params.admin, _params.keeper, _params.usdc, "Sandclock USDC Vault v2", "scUSDCv2")
        UsdcWethLendingManager(_params.usdc, _params.weth, _params.aaveV3, _params.aaveV2, _params.euler)
    {
        scWETH = _params.scWETH;
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
     * @notice Set the slippage tolerance for swapping WETH to USDC on Uniswap.
     * @param _newSlippageTolerance The new slippage tolerance value.
     */
    function setSlippageTolerance(uint256 _newSlippageTolerance) external onlyAdmin {
        if (_newSlippageTolerance > C.ONE) revert InvalidSlippageTolerance();

        slippageTolerance = _newSlippageTolerance;

        emit SlippageToleranceUpdated(msg.sender, _newSlippageTolerance);
    }

    /**
     * @notice Set the chainlink price feed for USDC -> WETH.
     * @param _newPriceFeed The new price feed.
     */
    function setUsdcToEthPriceFeed(AggregatorV3Interface _newPriceFeed) external onlyAdmin {
        if (address(_newPriceFeed) == address(0)) revert PriceFeedZeroAddress();

        usdcToEthPriceFeed = _newPriceFeed;
    }

    /**
     * @notice Rebalance the vault's positions.
     * @dev Called to increase or decrease the WETH debt to maintain the LTV (loan to value).
     */
    function rebalance(RebalanceParams[] calldata _params) public onlyKeeper {
        for (uint8 i = 0; i < _params.length; i++) {
            ProtocolActions memory protocolActions = protocolToActions[_params[i].protocolId];

            // respect new deposits
            if (_params[i].supplyAmount != 0) {
                protocolActions.supply(_params[i].supplyAmount);
            }

            // borrow and invest or disinvest and repay
            if (_params[i].leverageUp) {
                uint256 maxLtv = protocolActions.getMaxLtv();
                uint256 expectedLtv = getUsdcFromWeth(protocolActions.getDebt() + _params[i].wethAmount).divWadUp(
                    protocolActions.getCollateral()
                );

                if (expectedLtv >= maxLtv) {
                    revert LtvAboveMaxAllowed(Protocol(_params[i].protocolId));
                }

                protocolActions.borrow(_params[i].wethAmount);
                scWETH.deposit(_params[i].wethAmount, address(this));
            } else {
                uint256 withdrawn = _disinvest(_params[i].wethAmount);
                protocolActions.repay(withdrawn);
            }

            emit Rebalanced(
                _params[i].protocolId, _params[i].supplyAmount, _params[i].leverageUp, _params[i].wethAmount
            );
        }

        uint256 float = usdcBalance();
        uint256 floatRequired = totalAssets().mulWadDown(floatPercentage);

        if (float < floatRequired) {
            revert FloatBalanceTooSmall(float, floatRequired);
        }
    }

    function sellProfit(uint256 _usdcAmountOutMin) public onlyKeeper {
        uint256 profit = _calculateWethProfit(wethInvested(), totalDebt());

        if (profit == 0) revert NoProfitsToSell();

        uint256 withdrawn = _disinvest(profit);
        uint256 usdcReceived = _swapWethForUsdc(withdrawn, _usdcAmountOutMin);

        emit ProfitSold(withdrawn, usdcReceived);
    }

    /**
     * @notice Reallocate capital between lending markets, ie moves debt and collateral from one protocol to another.
     * @param _params The reallocation parameters. Markets where positions are downsized must be listed first because collateral has to be relased before it is reallocated.
     * @param _flashLoanAmount The amount of WETH to flashloan from Balancer. Has to be at least equal to amount of WETH debt moved between lending markets.
     */
    function reallocateCapital(ReallocationParams[] calldata _params, uint256 _flashLoanAmount) external onlyKeeper {
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
     * @notice Emergency exit to release collateral if the vault is underwater.
     * @param _endUsdcBalanceMin The minimum USDC balance to end with after all positions are closed.
     */
    function exitAllPositions(uint256 _endUsdcBalanceMin) external onlyAdmin {
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

    function receiveFlashLoan(address[] memory, uint256[] memory amounts, uint256[] memory, bytes memory userData)
        external
    {
        _isFlashLoanInitiated();

        if (msg.sender != address(balancerVault)) revert InvalidFlashLoanCaller();

        uint256 flashLoanAmount = amounts[0];
        FlashLoanType flashLoanType = abi.decode(userData, (FlashLoanType));

        if (flashLoanType == FlashLoanType.ExitAllPositions) {
            _exitAllPositionsFlash(flashLoanAmount);
        } else {
            (, ReallocationParams[] memory params) = abi.decode(userData, (FlashLoanType, ReallocationParams[]));
            _reallocateCapital(params);
            weth.safeTransfer(address(balancerVault), flashLoanAmount);
        }
    }

    function totalAssets() public view override returns (uint256) {
        return _calculateTotalAssets(usdcBalance(), totalCollateral(), wethInvested(), totalDebt());
    }

    function getUsdcFromWeth(uint256 _wethAmount) public view returns (uint256) {
        (, int256 usdcPriceInWeth,,,) = usdcToEthPriceFeed.latestRoundData();

        return (_wethAmount / C.WETH_USDC_DECIMALS_DIFF).divWadDown(uint256(usdcPriceInWeth));
    }

    function getWethFromUsdc(uint256 _usdcAmount) public view returns (uint256) {
        (, int256 usdcPriceInWeth,,,) = usdcToEthPriceFeed.latestRoundData();

        return (_usdcAmount * C.WETH_USDC_DECIMALS_DIFF).mulWadDown(uint256(usdcPriceInWeth));
    }

    /**
     * @notice Returns the USDC balance of the vault.
     * @return The USDC balance.
     */
    function usdcBalance() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Returns the total USDC supplied as collateral to Aave.
     * @return total supplied USDC amount.
     */
    function totalCollateral() public view returns (uint256 total) {
        for (uint8 i = 0; i <= uint256(type(Protocol).max); i++) {
            total += protocolToActions[Protocol(i)].getCollateral();
        }
    }

    /**
     * @notice Returns the total WETH borrowed on Aave.
     * @return total borrowed WETH amount.
     */
    function totalDebt() public view returns (uint256 total) {
        for (uint8 i = 0; i <= uint256(type(Protocol).max); i++) {
            total += protocolToActions[Protocol(i)].getDebt();
        }
    }

    /**
     * @notice Returns the amount of WETH invested in the leveraged WETH vault.
     * @return The WETH invested amount.
     */
    function wethInvested() public view returns (uint256) {
        return scWETH.convertToAssets(scWETH.balanceOf(address(this)));
    }

    /**
     * @notice Returns the amount of profit made by the vault.
     * @return The profit amount in WETH.
     */
    function getProfit() public view returns (uint256) {
        return _calculateWethProfit(wethInvested(), totalDebt());
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL API
    //////////////////////////////////////////////////////////////*/

    function _reallocateCapital(ReallocationParams[] memory _params) internal {
        for (uint8 i = 0; i < _params.length; i++) {
            ProtocolActions memory protocolActions = protocolToActions[_params[i].protocolId];

            if (_params[i].isDownsize) {
                protocolActions.repay(_params[i].debtAmount);
                protocolActions.withdraw(_params[i].collateralAmount);
            } else {
                protocolActions.supply(_params[i].collateralAmount);
                protocolActions.borrow(_params[i].debtAmount);
            }

            emit Reallocated(
                _params[i].protocolId, _params[i].isDownsize, _params[i].collateralAmount, _params[i].debtAmount
            );
        }
    }

    function _exitAllPositionsFlash(uint256 _flashLoanAmount) internal {
        for (uint8 i = 0; i <= uint256(type(Protocol).max); i++) {
            ProtocolActions memory protocolActions = protocolToActions[Protocol(i)];
            uint256 debt = protocolActions.getDebt();
            uint256 collateral = protocolActions.getCollateral();

            if (debt > 0) {
                protocolActions.repay(debt);
                protocolActions.withdraw(collateral);
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

        weth.safeTransfer(address(balancerVault), _flashLoanAmount);
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
        for (uint8 i = 0; i <= uint256(type(Protocol).max); i++) {
            uint256 protocolCollateral = protocolToActions[Protocol(i)].getCollateral();

            if (protocolCollateral == 0) continue;

            uint256 allocationPct = protocolCollateral.divWadDown(_collateral);

            protocolToActions[Protocol(i)].repay(withdrawn.mulWadUp(allocationPct));
            protocolToActions[Protocol(i)].withdraw(_usdcNeeded.mulWadUp(allocationPct));
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

    function _disinvest(uint256 _wethAmount) internal returns (uint256 amountWithdrawn) {
        uint256 shares = scWETH.convertToShares(_wethAmount);

        amountWithdrawn = scWETH.redeem(shares, address(this), address(this));
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
