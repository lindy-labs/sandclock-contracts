// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {IEulerDToken, IEulerEToken, IEulerMarkets} from "euler/IEuler.sol";
import {ISwapRouter} from "../interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {sc4626} from "../sc4626.sol";

contract scUSDC is sc4626 {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    using FixedPointMathLib for uint256;

    error InvalidTargetLtv();
    error EULSwapFailed();
    error InvalidSlippageTolerance();

    event NewTargetLtvApplied(uint256 newtargetLtv);
    event SlippageToleranceUpdated(uint256 newSlippageTolerance);
    event Rebalanced(uint256 collateral, uint256 debt, uint256 ltv);

    WETH public constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    ERC20 public constant usdc = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    uint256 constant ONE = 1e18;
    uint256 constant WETH_USDC_DECIMALS_DIFF = 1e12;
    // vaule used to scale the token's collateral/borrow factors from the euler market
    uint32 constant CONFIG_FACTOR_SCALE = 4_000_000_000;
    // delta threshold for rebalancing in percentage
    uint256 constant DEBT_DELTA_THRESHOLD = 0.01e18;

    address public constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;

    // euler rewards token EUL
    ERC20 public eul = ERC20(0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b);

    // The Euler market contract
    IEulerMarkets public constant markets = IEulerMarkets(0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3);

    // Euler supply token for USDC (eUSDC)
    IEulerEToken public constant eToken = IEulerEToken(0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716);

    // Euler debt token for WETH (dWETH)
    IEulerDToken public constant dToken = IEulerDToken(0x62e28f054efc24b26A794F5C1249B6349454352C);

    // Uniswap V3 router
    ISwapRouter public swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    // 0x swap router
    address public constant xrouter = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    // Chainlink pricefeed (USDC -> WETH)
    AggregatorV3Interface public constant usdcToEthPriceFeed =
        AggregatorV3Interface(0x986b5E1e1755e3C2440e960477f25201B0a8bbD4);

    // USDC / WETH target LTV
    uint256 public targetLtv = 0.65e18;
    // max slippage for swapping WETH -> USDC
    uint256 public slippageTolerance = 0.99e18; // 1% default
    uint256 public rebalanceMinimum = 10e6; // 10 USDC

    // leveraged (w)eth vault
    ERC4626 public immutable scWETH;

    constructor(address _admin, ERC4626 _scWETH) sc4626(_admin, usdc, "Sandclock USDC Vault", "scUSDC") {
        scWETH = _scWETH;

        usdc.safeApprove(EULER, type(uint256).max);

        weth.safeApprove(EULER, type(uint256).max);
        weth.safeApprove(address(swapRouter), type(uint256).max);
        weth.safeApprove(address(_scWETH), type(uint256).max);

        markets.enterMarket(0, address(usdc));
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC API
    //////////////////////////////////////////////////////////////*/

    function setSlippageTolerance(uint256 _slippageTolerance) external onlyAdmin {
        if (_slippageTolerance > ONE) revert InvalidSlippageTolerance();

        slippageTolerance = _slippageTolerance;

        emit SlippageToleranceUpdated(_slippageTolerance);
    }

    function applyNewTargetLtv(uint256 _newTargetLtv) external onlyKeeper {
        if (_newTargetLtv > getMaxLtv()) revert InvalidTargetLtv();

        targetLtv = _newTargetLtv;

        rebalance();

        emit NewTargetLtvApplied(_newTargetLtv);
    }

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
        if (balance > floatRequired && balance - floatRequired >= rebalanceMinimum) {
            eToken.deposit(0, balance - floatRequired);
            collateral += balance - floatRequired;
        }

        // 3. rebalance to target ltv
        uint256 targetDebt = getWethFromUsdc(collateral.mulWadDown(targetLtv));
        uint256 delta = debt > targetDebt ? debt - targetDebt : targetDebt - debt;

        if (delta <= targetDebt.mulWadDown(DEBT_DELTA_THRESHOLD)) return;

        // either repay or take out more debt to get to the target ltv
        if (debt > targetDebt) {
            _disinvest(delta);
            dToken.repay(0, delta);
        } else {
            dToken.borrow(0, delta);
            scWETH.deposit(delta, address(this));
        }

        uint256 collateralAfter = getCollateral();
        uint256 debtAfter = getDebt();
        emit Rebalanced(collateralAfter, debtAfter, _calculateLtv(collateralAfter, debtAfter));
    }

    /// note: euler rewards can be claimed by another account, we only have to swap them here using 0xrouter
    function reinvestEulerRewards(bytes calldata _swapData) public onlyKeeper {
        uint256 eulBalance = eul.balanceOf(address(this));

        if (eulBalance == 0) return;

        // swap EUL -> WETH
        eul.safeApprove(xrouter, eulBalance);
        (bool success,) = xrouter.call{value: 0}(_swapData);
        if (!success) revert EULSwapFailed();

        rebalance();
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

    function getUsdcBalance() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    // total USDC supplied as collateral to euler
    function getCollateral() public view returns (uint256) {
        return eToken.balanceOfUnderlying(address(this));
    }

    // total eth borrowed on euler
    function getDebt() public view returns (uint256) {
        return dToken.balanceOf(address(this));
    }

    function getWethInvested() public view returns (uint256) {
        return scWETH.convertToAssets(scWETH.balanceOf(address(this)));
    }

    // returns the net LTV at which we have borrowed untill now (1e18 = 100%)
    function getLtv() public view returns (uint256) {
        uint256 debt = getDebt();

        if (debt == 0) return 0;

        uint256 debtPriceInUsdc = getUsdcFromWeth(debt);

        // totalDebt / totalSupplied
        return debtPriceInUsdc.divWadUp(getCollateral());
    }

    // gets the current max LTV for USDC / WETH loans on euler
    function getMaxLtv() public view returns (uint256) {
        uint256 collateralFactor = markets.underlyingToAssetConfig(address(usdc)).collateralFactor;
        uint256 borrowFactor = markets.underlyingToAssetConfig(address(weth)).borrowFactor;

        uint256 scaledCollateralFactor = collateralFactor.divWadDown(CONFIG_FACTOR_SCALE);
        uint256 scaledBorrowFactor = borrowFactor.divWadDown(CONFIG_FACTOR_SCALE);

        return scaledCollateralFactor.mulWadDown(scaledBorrowFactor);
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
        // if we don't have enough assets, we need to withdraw what's missing from scWETH & euler
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
            // so we sell as much as we can and withdraw the rest from euler
            _disinvest(wethProfit);
            usdcNeeded -= _swapWethForUsdc(wethProfit);
            wethInvested -= wethProfit;
        }

        // to keep the same ltv, weth debt to repay has to be proporitional to collateral withdrawn
        uint256 wethNeeded = usdcNeeded.mulDivUp(wethDebt, collateral);

        if (wethNeeded > wethInvested) {
            _disinvest(wethInvested);
            dToken.repay(0, wethDebt);
            eToken.withdraw(0, collateral);
        } else {
            _disinvest(wethNeeded);
            dToken.repay(0, wethNeeded);
            eToken.withdraw(0, usdcNeeded);
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
