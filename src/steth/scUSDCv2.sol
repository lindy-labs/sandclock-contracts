// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {
    InvalidTargetLtv,
    InvalidSlippageTolerance,
    InvalidFlashLoanCaller,
    VaultNotUnderwater,
    NoProfitsToSell
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

// TODO: add modifiers to all functions where applicable
// TODO: add function for harvesting EULER reward tokens
// TODO: add function to change price feed
// TODO: add AAVE v2 support
// TODO: add exit all positions
/**
 * @title Sandclock USDC Vault
 * @notice A vault that allows users to earn interest on their USDC deposits from leveraged WETH staking.
 * @dev This vault uses Sandclock's leveraged WETH staking vault - scWETH.
 */
contract scUSDCv2 is sc4626, UsdcWethLendingManager, IFlashLoanRecipient {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    using FixedPointMathLib for uint256;

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
    AggregatorV3Interface public immutable usdcToEthPriceFeed;

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
        IPool aavePool;
        IPoolDataProvider aavePoolDataProvider;
        IAToken aaveAUsdc;
        ERC20 aaveVarDWeth;
        ISwapRouter uniswapSwapRouter;
        AggregatorV3Interface chainlinkUsdcToEthPriceFeed;
        IVault balancerVault;
        address eulerProtocol;
        IEulerMarkets eulerMarkets;
        IEulerEToken eulerEUsdc;
        IEulerDToken eulerDWeth;
        ERC20 eulerRewardsToken;
    }

    constructor(ConstructorParams memory _params)
        sc4626(_params.admin, _params.keeper, _params.usdc, "Sandclock USDC Vault v2", "scUSDCv2")
        UsdcWethLendingManager(
            _params.usdc,
            _params.weth,
            _params.aavePool,
            _params.aavePoolDataProvider,
            _params.aaveAUsdc,
            _params.aaveVarDWeth,
            _params.eulerProtocol,
            _params.eulerMarkets,
            _params.eulerEUsdc,
            _params.eulerDWeth,
            _params.eulerRewardsToken
        )
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
     * @notice Reallocate capital between lending markets, ie moves debt and collateral from one protocol to another.
     * @param _params The reallocation parameters. Markets where positions are downsized must be listed first because collateral has to be relased before it is reallocated.
     * @param _flashLoanAmount The amount of WETH to flashloan from Balancer. Has to be at least equal to amount of WETH debt moved between lending markets.
     */
    function reallocateCapital(ReallocationParams[] calldata _params, uint256 _flashLoanAmount) public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _flashLoanAmount;

        _initiateFlashLoan();
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(_params));
        _finalizeFlashLoan();
    }

    function receiveFlashLoan(address[] memory, uint256[] memory amounts, uint256[] memory, bytes memory userData)
        external
    {
        _isFlashLoanInitiated();

        if (msg.sender != address(balancerVault)) {
            revert InvalidFlashLoanCaller();
        }

        uint256 flashLoanAmount = amounts[0];
        (ReallocationParams[] memory params) = abi.decode(userData, (ReallocationParams[]));

        for (uint8 i = 0; i < params.length; i++) {
            ProtocolActions memory protocolActions = protocolToActions[params[i].protocolId];

            if (params[i].isDownsize) {
                protocolActions.repay(params[i].debtAmount);
                protocolActions.withdraw(params[i].collateralAmount);
            } else {
                protocolActions.supply(params[i].collateralAmount);
                protocolActions.borrow(params[i].debtAmount);
            }

            emit Reallocated(
                params[i].protocolId, params[i].isDownsize, params[i].collateralAmount, params[i].debtAmount
            );
        }

        weth.safeTransfer(address(balancerVault), flashLoanAmount);
    }

    /**
     * @notice Rebalance the vault's positions.
     * @dev Called to increase or decrease the WETH debt to maintain the LTV (loan to value).
     */
    function rebalance(RebalanceParams[] calldata _params) public {
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

    /**
     * @notice Struct to store lending position related information
     */
    struct LendingPositionInfo {
        Protocol protocolId; // ID of the protocol
        uint256 collateral; // Amount of collateral
        uint256 debt; // Amount of debt
        uint256 ltv; // Loan-to-Value (LTV) ratio
    }

    /**
     * @notice Fetches position-related information for each protocol in the input list
     * @param _protocolIds An array of protocol identifiers for which to fetch position info
     * @return positionInfos An array of LendingPositionInfo structs containing the position info for each input protocol
     *
     * @dev Each LendingPositionInfo struct in the output array corresponds to the protocol with the same index in the input array.
     * If the collateral for a position is 0, the LTV for that position is also 0.
     */
    function getPositionInfos(Protocol[] calldata _protocolIds)
        external
        view
        returns (LendingPositionInfo[] memory positionInfos)
    {
        positionInfos = new LendingPositionInfo[](_protocolIds.length);

        for (uint8 i = 0; i < _protocolIds.length; i++) {
            Protocol protocolId = _protocolIds[i];

            ProtocolActions memory protocolActions = protocolToActions[protocolId];
            LendingPositionInfo memory positionInfo;

            positionInfo.protocolId = protocolId;
            positionInfo.collateral = protocolActions.getCollateral();
            positionInfo.debt = protocolActions.getDebt();

            // calculate ltv
            if (positionInfo.collateral != 0) {
                positionInfo.ltv = getUsdcFromWeth(positionInfo.debt).divWadUp(positionInfo.collateral);
            }

            positionInfos[i] = positionInfo;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL API
    //////////////////////////////////////////////////////////////*/

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
