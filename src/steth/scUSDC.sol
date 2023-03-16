// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";

import {IVault} from "../interfaces/balancer/IVault.sol";
import {ISwapRouter} from "../interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";
import {sc4626} from "../sc4626.sol";

/**
 * @title Sandclock USDC Vault
 * @notice A vault that allows users to earn interest on their USDC deposits from leveraged WETH staking.
 * @dev This vault uses Sanclodk's leveraged WETH staking vault - scWETH.
 */
contract scUSDC is sc4626, IFlashLoanRecipient {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    using FixedPointMathLib for uint256;

    error InvalidTargetLtv();
    error EULSwapFailed();
    error InvalidSlippageTolerance();
    error InvalidFlashLoanCaller();
    error VaultNotUnderwater();

    event NewTargetLtvApplied(address indexed admin, uint256 newTargetLtv);
    event SlippageToleranceUpdated(address indexed admin, uint256 newSlippageTolerance);
    event EmergencyExitExecuted(
        address indexed admin, uint256 wethWithdrawn, uint256 debtRepaid, uint256 collateralReleased
    );
    event Rebalanced(uint256 collateral, uint256 debt, uint256 ltv);

    WETH public constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    ERC20 public constant usdc = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    uint256 constant ONE = 1e18;
    uint256 constant WETH_USDC_DECIMALS_DIFF = 1e12;
    // delta threshold for rebalancing in percentage
    uint256 constant DEBT_DELTA_THRESHOLD = 0.01e18;
    uint256 constant AAVE_VAR_INTEREST_RATE_MODE = 2;

    // main aave contract for interaction with the protocol
    IPool public constant aavePool = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    // aave protocol data provider
    IPoolDataProvider aavePoolDataProvider = IPoolDataProvider(0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3);

    // aave "aEthUSDC" token
    IAToken aUsdc = IAToken(0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c);
    // aave "variableDebtEthWETH" token
    ERC20 dWeth = ERC20(0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE);

    // Uniswap V3 router
    ISwapRouter public swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    // Chainlink pricefeed (USDC -> WETH)
    AggregatorV3Interface public constant usdcToEthPriceFeed =
        AggregatorV3Interface(0x986b5E1e1755e3C2440e960477f25201B0a8bbD4);

    // Balancer vault for flashloans
    IVault public constant balancerVault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    // USDC / WETH target LTV
    uint256 public targetLtv = 0.65e18;
    // max slippage for swapping WETH -> USDC
    uint256 public slippageTolerance = 0.99e18; // 1% default
    uint256 public rebalanceMinimum = 10e6; // 10 USDC

    // leveraged (w)eth vault
    ERC4626 public immutable scWETH;

    constructor(address _admin, ERC4626 _scWETH) sc4626(_admin, usdc, "Sandclock USDC Vault", "scUSDC") {
        scWETH = _scWETH;

        usdc.safeApprove(address(aavePool), type(uint256).max);

        weth.safeApprove(address(aavePool), type(uint256).max);
        weth.safeApprove(address(swapRouter), type(uint256).max);
        weth.safeApprove(address(_scWETH), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC API
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the slippage tolerance for swapping WETH to USDC on Uniswap.
     * @param _newSlippageTolerance The new slippage tolerance value.
     */
    function setSlippageTolerance(uint256 _newSlippageTolerance) external onlyAdmin {
        if (_newSlippageTolerance > ONE) revert InvalidSlippageTolerance();

        slippageTolerance = _newSlippageTolerance;

        emit SlippageToleranceUpdated(msg.sender, _newSlippageTolerance);
    }

    /**
     * @notice Apply a new target LTV and trigger a rebalance.
     * @param _newTargetLtv The new target LTV value.
     */
    function applyNewTargetLtv(uint256 _newTargetLtv) external onlyKeeper {
        if (_newTargetLtv > getMaxLtv()) revert InvalidTargetLtv();

        targetLtv = _newTargetLtv;

        rebalance();

        emit NewTargetLtvApplied(msg.sender, _newTargetLtv);
    }

    /**
     * @notice Rebalance the vault's positions.
     * @dev Called to increase or decrease the WETH debt to match the target LTV.
     */
    function rebalance() public {
        uint256 balance = getUsdcBalance();
        uint256 collateral = getCollateral();
        uint256 invested = getWethInvested();
        uint256 debt = getDebt();

        // 1. sell profits if any
        if (invested > debt) {
            uint256 profit = invested - debt;
            if (profit > invested.mulWadDown(DEBT_DELTA_THRESHOLD)) {
                _disinvest(profit);
                balance += _swapWethForUsdc(profit);
                invested -= profit;
            }
        }

        uint256 floatRequired = _calculateTotalAssets(balance, collateral, invested, debt).mulWadDown(floatPercentage);

        // 2. deposit excess usdc as collateral
        uint256 excessUsdc = balance > floatRequired ? balance - floatRequired : 0;
        if (excessUsdc != 0 && excessUsdc >= rebalanceMinimum) {
            aavePool.supply(address(usdc), excessUsdc, address(this), 0);
            collateral += excessUsdc;
        }

        // 3. rebalance to target ltv
        uint256 targetDebt = getWethFromUsdc(collateral.mulWadDown(targetLtv));
        uint256 delta = debt > targetDebt ? debt - targetDebt : targetDebt - debt;

        if (delta <= targetDebt.mulWadDown(DEBT_DELTA_THRESHOLD)) return;

        // either repay or take out more debt to get to the target ltv
        if (debt > targetDebt) {
            _disinvest(delta);
            aavePool.repay(address(weth), delta, AAVE_VAR_INTEREST_RATE_MODE, address(this));
        } else {
            aavePool.borrow(address(weth), delta, AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
            scWETH.deposit(delta, address(this));
        }

        uint256 collateralAfter = getCollateral();
        uint256 debtAfter = getDebt();
        emit Rebalanced(collateralAfter, debtAfter, _calculateLtv(collateralAfter, debtAfter));
    }

    /**
     * @notice Emergency exit to release collateral if the vault is underwater.
     */
    function exitAllPositions() external onlyAdmin {
        uint256 wethInvested = getWethInvested();
        uint256 wethDebt = getDebt();

        if (wethInvested >= wethDebt) {
            revert VaultNotUnderwater();
        }

        scWETH.withdraw(wethInvested, address(this), address(this));
        uint256 collateral = getCollateral();

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = wethDebt - wethInvested;

        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(collateral, wethDebt));

        emit EmergencyExitExecuted(msg.sender, wethInvested, wethDebt, collateral);
    }

    /**
     * @notice Handles the repayment and collateral release logic for flash loans.
     * @param userData Data passed to the callback function.
     */
    function receiveFlashLoan(address[] memory, uint256[] memory amounts, uint256[] memory, bytes memory userData)
        external
    {
        if (msg.sender != address(balancerVault)) {
            revert InvalidFlashLoanCaller();
        }

        uint256 flashLoanAmount = amounts[0];
        (uint256 collateral, uint256 wethDebt) = abi.decode(userData, (uint256, uint256));

        aavePool.repay(address(weth), wethDebt, AAVE_VAR_INTEREST_RATE_MODE, address(this));
        aavePool.withdraw(address(usdc), collateral, address(this));

        asset.approve(address(swapRouter), type(uint256).max);

        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: address(asset),
            tokenOut: address(weth),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountOut: flashLoanAmount,
            amountInMaximum: type(uint256).max, // ignore slippage
            sqrtPriceLimitX96: 0
        });

        swapRouter.exactOutputSingle(params);

        asset.approve(address(swapRouter), 0);

        weth.safeTransfer(address(balancerVault), flashLoanAmount);
    }

    function totalAssets() public view override returns (uint256) {
        return _calculateTotalAssets(getUsdcBalance(), getCollateral(), getWethInvested(), getDebt());
    }

    function getUsdcFromWeth(uint256 _wethAmount) public view returns (uint256) {
        (, int256 usdcPriceInWeth,,,) = usdcToEthPriceFeed.latestRoundData();

        return _wethAmount.divWadDown(uint256(usdcPriceInWeth)) / WETH_USDC_DECIMALS_DIFF;
    }

    function getWethFromUsdc(uint256 _usdcAmount) public view returns (uint256) {
        (, int256 usdcPriceInWeth,,,) = usdcToEthPriceFeed.latestRoundData();

        return (_usdcAmount * WETH_USDC_DECIMALS_DIFF).mulWadDown(uint256(usdcPriceInWeth));
    }

    /**
     * @notice Returns the USDC balance of the vault.
     * @return The USDC balance.
     */
    function getUsdcBalance() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Returns the total USDC supplied as collateral to Aave.
     * @return The USDC collateral amount.
     */
    function getCollateral() public view returns (uint256) {
        return aUsdc.balanceOf(address(this));
    }

    /**
     * @notice Returns the total WETH borrowed on Aave.
     * @return The borrowed WETH amount.
     */
    function getDebt() public view returns (uint256) {
        return dWeth.balanceOf(address(this));
    }

    /**
     * @notice Returns the amount of WETH invested in the leveraged WETH vault.
     * @return The WETH invested amount.
     */
    function getWethInvested() public view returns (uint256) {
        return scWETH.convertToAssets(scWETH.balanceOf(address(this)));
    }

    /**
     * @notice Returns the net LTV at which the vault has borrowed until now.
     * @return The current LTV (1e18 = 100%).
     */
    function getLtv() public view returns (uint256) {
        uint256 debt = getDebt();

        if (debt == 0) return 0;

        uint256 debtPriceInUsdc = getUsdcFromWeth(debt);

        // totalDebt / totalSupplied
        return debtPriceInUsdc.divWadUp(getCollateral());
    }

    /**
     * @notice Returns the current max LTV for USDC / WETH loans on Aave.
     * @return The max LTV (1e18 = 100%).
     */
    function getMaxLtv() public view returns (uint256) {
        (, uint256 ltv,,,,,,,,) = aavePoolDataProvider.getReserveConfigurationData(address(usdc));

        return ltv * 1e14;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL API
    //////////////////////////////////////////////////////////////*/

    function beforeWithdraw(uint256 _assets, uint256) internal override {
        uint256 balance = getUsdcBalance();
        if (_assets <= balance) return;

        uint256 collateral = getCollateral();
        uint256 wethDebt = getDebt();
        uint256 wethInvested = getWethInvested();
        // if we don't have enough assets, we need to withdraw what's missing from scWETH & aave
        uint256 total = _calculateTotalAssets(balance, collateral, wethInvested, wethDebt);
        uint256 floatRequired = total > _assets ? (total - _assets).mulWadUp(floatPercentage) : 0;
        uint256 usdcNeeded = _assets + floatRequired - balance;

        if (wethInvested > wethDebt) {
            uint256 wethProfit = wethInvested - wethDebt;
            uint256 wethToSell = getWethFromUsdc(usdcNeeded).divWadDown(slippageTolerance); // account for slippage

            if (wethProfit >= wethToSell) {
                // we cover withdrawal amount from selling weth profit
                _disinvest(wethToSell);
                _swapWethForUsdc(wethToSell);

                return;
            }

            // we cannot cover withdrawal amount only from selling weth profit
            // so we sell as much as we can and withdraw the rest from aave
            _disinvest(wethProfit);
            usdcNeeded -= _swapWethForUsdc(wethProfit);
            wethInvested -= wethProfit;
        }

        // to keep the same ltv, weth debt to repay has to be proporitional to collateral withdrawn
        uint256 wethNeeded = usdcNeeded.mulDivUp(wethDebt, collateral);

        if (wethNeeded > wethInvested) {
            uint256 usdcToWithdraw = wethInvested.mulDivUp(collateral, wethDebt);

            _disinvest(wethInvested);
            aavePool.repay(address(weth), wethInvested, AAVE_VAR_INTEREST_RATE_MODE, address(this));
            aavePool.withdraw(address(usdc), usdcToWithdraw, address(this));
        } else {
            _disinvest(wethNeeded);
            aavePool.repay(address(weth), wethNeeded, AAVE_VAR_INTEREST_RATE_MODE, address(this));
            aavePool.withdraw(address(usdc), usdcNeeded, address(this));
        }
    }

    function _calculateTotalAssets(uint256 _float, uint256 _collateral, uint256 _wethInvested, uint256 _wethDebt)
        internal
        view
        returns (uint256 total)
    {
        total = _float + _collateral + getUsdcFromWeth(_wethInvested) - getUsdcFromWeth(_wethDebt);

        // account for slippage when selling weth profits
        if (_wethInvested > _wethDebt) {
            total -= getUsdcFromWeth(_wethInvested - _wethDebt).mulWadUp(ONE - slippageTolerance);
        }
    }

    function _calculateLtv(uint256 collateral, uint256 debt) internal view returns (uint256) {
        return getUsdcFromWeth(debt).divWadUp(collateral);
    }

    function _disinvest(uint256 _wethAmount) internal {
        scWETH.withdraw(_wethAmount, address(this), address(this));
    }

    function _swapWethForUsdc(uint256 _wethAmount) internal returns (uint256) {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(asset),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _wethAmount,
            amountOutMinimum: getUsdcFromWeth(_wethAmount).mulWadDown(slippageTolerance),
            sqrtPriceLimitX96: 0
        });

        return swapRouter.exactInputSingle(params);
    }
}
