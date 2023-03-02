// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IMarkets} from "../interfaces/euler/IMarkets.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IEulerDToken} from "../interfaces/euler/IEulerDToken.sol";
import {IEulerEToken} from "../interfaces/euler/IEulerEToken.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {sc4626} from "../sc4626.sol";
import {ISwapRouter} from "../interfaces/uniswap/ISwapRouter.sol";

import "forge-std/console2.sol";

// TODOs: 1. harvest euler rewards - add test
//        2. add tolerance when comapring ltv-s
contract scUSDC is sc4626 {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    using FixedPointMathLib for uint256;

    error InvalidTargetLtv();
    error EULSwapFailed();
    error InvalidSlippageTolerance();
    error SlippageTooHigh();

    event NewTargetLtvApplied(uint256 newtargetLtv);
    event SlippageToleranceUpdated(uint256 newSlippageTolerance);
    event Rebalanced(uint256 collateral, uint256 debt, uint256 ltv);

    WETH public constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    ERC20 public constant usdc = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    uint256 constant ONE = 1e18;
    // vaule used to scale the token's collateral/borrow factors from the euler market
    uint32 constant CONFIG_FACTOR_SCALE = 4_000_000_000;

    address public constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;
    // euler rewards token EUL
    ERC20 public eul = ERC20(0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b);
    // The Euler market contract
    IMarkets public constant markets = IMarkets(0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3);
    // Euler supply token for USDC (eUSDC)
    IEulerEToken public constant eToken = IEulerEToken(0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716);
    // Euler debt token for WETH (dWETH)
    IEulerDToken public constant dToken = IEulerDToken(0x62e28f054efc24b26A794F5C1249B6349454352C);

    // Uniswap V3 router
    ISwapRouter public constant swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    // 0x swap router
    address public constant xrouter = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    // Chainlink pricefeed (USDC -> WETH)
    AggregatorV3Interface public constant usdcToEthPriceFeed =
        AggregatorV3Interface(0x986b5E1e1755e3C2440e960477f25201B0a8bbD4);

    // USDC / WETH target LTV
    uint256 public targetLtv = 0.65e18;
    // max slippage for swapping WETH -> USDC
    uint256 public slippageTolerance = 0.01e18; // 1% default

    // lev (w)eth vault
    ERC4626 public immutable scWETH;

    constructor(address _admin, ERC4626 _scWETH) sc4626(_admin, usdc, "Sandclock USDC Vault", "scUSDC") {
        scWETH = _scWETH;

        usdc.safeApprove(EULER, type(uint256).max);

        weth.safeApprove(EULER, type(uint256).max);
        weth.safeApprove(address(swapRouter), type(uint256).max);
        weth.safeApprove(address(_scWETH), type(uint256).max);

        eul.safeApprove(xrouter, type(uint256).max);

        markets.enterMarket(0, address(usdc));
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC API
    //////////////////////////////////////////////////////////////*/

    function setSlippageTolerance(uint256 _slippageTolerance) external onlyAdmin {
        if (_slippageTolerance > 1e18) revert InvalidSlippageTolerance();

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
        // first deposit if there is anything to deposit
        uint256 balance = usdcBalance();
        uint256 floatRequired = totalAssets().mulWadUp(floatPercentage);

        if (balance > floatRequired) {
            eToken.deposit(0, balance - floatRequired);
        }

        // second check ltv and see if we need to rebalance
        uint256 currentDebt = totalDebt();
        uint256 targetDebt = getWethFromUsdc(totalCollateralSupplied().mulWadDown(targetLtv));

        // TODO: add some tollarance when comparing ltvs, for ex 0.1%
        if (currentDebt == targetDebt) return;

        if (currentDebt > targetDebt) {
            // we need to withdraw weth from scWETH and repay debt on euler
            uint256 delta = currentDebt - targetDebt;

            scWETH.withdraw(delta, address(this), address(this));
            dToken.repay(0, delta);
        } else {
            // we need to borrow more weth on euler and deposit it in scWETH
            uint256 delta = targetDebt - currentDebt;

            dToken.borrow(0, delta);
            scWETH.deposit(delta, address(this));
        }

        emit Rebalanced(totalCollateralSupplied(), totalDebt(), getLtv());
    }

    /// note: euler rewards can be claimed by another account, we only have to swap them here using 0xrouter
    function reinvestEulerRewards(bytes calldata _swapData) public {
        if (eul.balanceOf(address(this)) == 0) return;

        // swap EUL -> WETH
        (bool success,) = xrouter.call{value: 0}(_swapData);
        if (!success) revert EULSwapFailed();

        rebalance();
    }

    function totalAssets() public view override returns (uint256 total) {
        // add float
        total = usdcBalance();

        // add collateral
        total += eToken.balanceOfUnderlying(address(this));

        // subtract debt
        total -= getUsdcFromWeth(totalDebt());

        // add invested amount
        total += getUsdcFromWeth(scWETH.convertToAssets(scWETH.balanceOf(address(this))));
    }

    function getUsdcFromWeth(uint256 _wethAmount) public view returns (uint256) {
        (, int256 usdcPriceInWeth,,,) = usdcToEthPriceFeed.latestRoundData();

        return _wethAmount.divWadDown(uint256(usdcPriceInWeth)) / 1e12;
    }

    function getWethFromUsdc(uint256 _usdcAmount) public view returns (uint256) {
        (, int256 usdcPriceInWeth,,,) = usdcToEthPriceFeed.latestRoundData();

        return (_usdcAmount * 1e12).mulWadDown(uint256(usdcPriceInWeth));
    }

    function usdcBalance() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    // total USDC supplied as collateral to euler
    function totalCollateralSupplied() public view returns (uint256) {
        return eToken.balanceOfUnderlying(address(this));
    }

    // total eth borrowed on euler
    function totalDebt() public view returns (uint256) {
        return dToken.balanceOf(address(this));
    }

    // returns the net LTV at which we have borrowed untill now (1e18 = 100%)
    function getLtv() public view returns (uint256) {
        uint256 debt = totalDebt();

        if (debt == 0) return 0;

        uint256 debtPriceInUsdc = getUsdcFromWeth(debt);

        // totalDebt / totalSupplied
        return debtPriceInUsdc.divWadUp(totalCollateralSupplied());
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
        uint256 balance = usdcBalance();
        // if we have enough assets, we don't need to withdraw from euler
        if (_assets <= balance) return;

        // if we don't have enough assets, we need to withdraw what's missing from scWETH & euler
        uint256 total = totalAssets();
        uint256 floatRequired = total > _assets ? (totalAssets() - _assets).mulWadUp(floatPercentage) : 0;
        uint256 usdcNeeded = _assets + floatRequired - balance;

        uint256 wethDebt = totalDebt();
        uint256 wethInvested = scWETH.convertToAssets(scWETH.balanceOf(address(this)));

        if (wethInvested > wethDebt) {
            // we have some profit in weth
            uint256 wethProfit = wethInvested - wethDebt;
            uint256 wethToWithdraw = getWethFromUsdc(usdcNeeded);

            if (wethProfit >= wethToWithdraw) {
                // we cover withdrawal amount from selling weth profit
                scWETH.withdraw(wethToWithdraw, address(this), address(this));
                _swapWethForUsdc(wethToWithdraw);

                return;
            }

            // we cannot cover withdrawal amount only from selling weth profit
            // so we sell as much as we can and withdraw the rest from euler
            scWETH.withdraw(wethProfit, address(this), address(this));
            usdcNeeded -= _swapWethForUsdc(wethProfit);
        }

        // to keep the same ltv, weth debt to repay has to be proporitional to collateral withdrawn
        uint256 collateral = totalCollateralSupplied();
        uint256 wethNeeded = usdcNeeded.mulDivUp(wethDebt, collateral);

        scWETH.withdraw(wethNeeded, address(this), address(this));

        // repay debt and take out collateral on euler
        dToken.repay(0, wethNeeded);
        eToken.withdraw(0, usdcNeeded);
    }

    function _swapWethForUsdc(uint256 _wethAmount) internal returns (uint256 amountOut) {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(asset),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _wethAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(params);

        uint256 minUsdcAmountOut = getUsdcFromWeth(_wethAmount).mulWadDown(1e18 - slippageTolerance);

        if (amountOut < minUsdcAmountOut) revert SlippageTooHigh();
    }
}
