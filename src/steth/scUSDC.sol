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

// TODOs: 1. add events
//        2. add leverage up/down & rebalancing?
//        3. harvest euler rewards
//        4. add tests
//        5. add code styile guidelines docs
contract scUSDC is sc4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    error InvalidUsdcWethTargetLtv();

    WETH public constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    ERC20 public constant usdc = ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    address public constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;
    // EUL token
    ERC20 eul = ERC20(0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b);
    // The Euler market contract
    IMarkets public constant markets = IMarkets(0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3);
    // Euler supply token for USDC (eUSDC)
    IEulerEToken public constant eToken = IEulerEToken(0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716);
    // Euler debt token for WETH (dWETH)
    IEulerDToken public constant dToken = IEulerDToken(0x62e28f054efc24b26A794F5C1249B6349454352C);

    // Uniswap V3 router
    ISwapRouter public constant swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    // 0x swap router
    address xrouter = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    // Chainlink pricefeed (USDC -> WETH)
    AggregatorV3Interface public constant usdcToEthPriceFeed =
        AggregatorV3Interface(0x986b5E1e1755e3C2440e960477f25201B0a8bbD4);

    ERC4626 public immutable scWETH;
    // TODO: see if this can change
    uint256 public immutable usdcWethMaxLtv = 0.81e18;
    uint256 public usdcWethTargetLtv = 0.65e18;

    constructor(address _admin, ERC4626 _scWETH) sc4626(_admin, usdc, "Sandclock USDC Vault", "scUSDC") {
        scWETH = _scWETH;
        usdc.approve(EULER, type(uint256).max);

        weth.approve(EULER, type(uint256).max);
        weth.approve(address(swapRouter), type(uint256).max);
        weth.approve(address(_scWETH), type(uint256).max);

        markets.enterMarket(0, address(usdc));
    }

    function setUsdcWethTargetLtvAndRebalance(uint256 _usdcWethTargetLtv) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_usdcWethTargetLtv > usdcWethMaxLtv || _usdcWethTargetLtv == 0) revert InvalidUsdcWethTargetLtv();

        usdcWethTargetLtv = _usdcWethTargetLtv;
        rebalance();
    }

    function totalAssets() public view override returns (uint256) {
        uint256 float = usdcBalance();
        uint256 collateral = eToken.balanceOfUnderlying(address(this));

        uint256 wethDebt = totalDebt();
        uint256 debtInUsdc = getUsdcFromWeth(wethDebt);

        uint256 wethInvested = scWETH.convertToAssets(scWETH.balanceOf(address(this)));
        uint256 investedInUsdc = getUsdcFromWeth(wethInvested);

        return float + collateral + investedInUsdc - debtInUsdc;
    }

    function getUsdcFromWeth(uint256 _wethAmount) public view returns (uint256) {
        (, int256 usdcPriceInWeth,,,) = usdcToEthPriceFeed.latestRoundData();

        return _wethAmount.divWadDown(uint256(usdcPriceInWeth)) / 1e12;
    }

    function getWethFromUsdc(uint256 _usdcAmount) public view returns (uint256) {
        (, int256 usdcPriceInWeth,,,) = usdcToEthPriceFeed.latestRoundData();

        return (_usdcAmount * 1e12).mulWadDown(uint256(usdcPriceInWeth));
    }

    function beforeWithdraw(uint256 _assets, uint256) internal override {
        uint256 balance = usdcBalance();
        // if we have enough assets, we don't need to withdraw from euler
        if (_assets <= balance) return;

        // if we don't have enough assets, we need to withdraw what's missing from scWETH & euler
        uint256 floatRequired = (totalAssets() - _assets).mulWadUp(1e18 - floatPercentage);
        uint256 usdcToWithdraw = _assets + floatRequired - balance;

        // to keep the same ltv, weth debt to repay has to be proporitional to collateral withdrawn
        uint256 wethDebt = totalDebt();
        uint256 wethInvested = scWETH.convertToAssets(scWETH.balanceOf(address(this)));

        if (wethInvested > wethDebt) {
            uint256 wethProfit = wethInvested - wethDebt;
            uint256 wethToWithdraw = usdcToWithdraw.mulWadUp(wethDebt).divWadUp(wethInvested);

            if (wethProfit >= wethToWithdraw) {
                // we can sell all weth
                scWETH.withdraw(wethToWithdraw, address(this), address(this));
                _swapWethForUSDC(wethToWithdraw);
                return;
            }

            // sell some and take rest to repay debt on euler
            scWETH.withdraw(wethProfit, address(this), address(this));
            uint256 usdcAmountOut = _swapWethForUSDC(wethProfit);
            usdcToWithdraw -= usdcAmountOut;
        }

        // at this point we need more weth to repay debt withdraw usdc collateral from euler
        uint256 collateral = totalCollateralSupplied();
        uint256 wethNeeded = usdcToWithdraw.mulWadUp(wethDebt).divWadUp(collateral);

        scWETH.withdraw(wethNeeded, address(this), address(this));

        // repay debt and take out collateral on euler
        dToken.repay(0, wethNeeded);
        eToken.withdraw(0, usdcToWithdraw);
    }

    // @dev: access control not needed, this is only separate to save
    // gas for users depositing, ultimately controlled by float %
    function depositIntoStrategy() external {
        // _depositIntoStrategy();
        rebalance();
    }

    function _depositIntoStrategy() internal {
        uint256 currentLtv = getLtv();

        if (currentLtv == 0) currentLtv = usdcWethTargetLtv;

        // supply usdc collateral to euler
        uint256 balance = usdcBalance();
        uint256 floatRequired = totalAssets().mulWadUp(1e18 - floatPercentage);

        if (balance < floatRequired) {
            // we have enough balance to deposit
            return;
        }

        uint256 depositAmount = balance - floatRequired;

        eToken.deposit(0, depositAmount);

        // borrow weth on euler
        uint256 wethToBorrow = currentLtv.mulWadUp(getWethFromUsdc(depositAmount));
        dToken.borrow(0, wethToBorrow);

        scWETH.deposit(wethToBorrow, address(this));
    }

    function rebalance() public {
        // first deposit if there is anything to deposit
        uint256 balance = usdcBalance();
        uint256 floatRequired = totalAssets().mulWadUp(1e18 - floatPercentage);
        if (balance > floatRequired) {
            eToken.deposit(0, balance - floatRequired);
        }

        // second check ltv and see if we need to rebalance
        uint256 currentDebt = totalDebt();
        uint256 targetDebt = getWethFromUsdc(totalCollateralSupplied().mulWadDown(usdcWethTargetLtv));

        // ToDO: add some tollarance when comparing ltvs, for ex 0.1%
        if (currentDebt > targetDebt) {
            // we need to withdraw weth from scWETH and repay debt on euler
            uint256 delta = currentDebt - targetDebt;

            scWETH.withdraw(delta, address(this), address(this));
            dToken.repay(0, delta);
        } else if (currentDebt < targetDebt) {
            // we need to borrow more weth on euler and deposit it in scWETH
            uint256 delta = targetDebt - currentDebt;

            dToken.borrow(0, delta);
            scWETH.deposit(delta, address(this));
        }
    }

    function harvest() public {
        // get euler rewards and swap to usdc

        rebalance();
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

    function _swapWethForUSDC(uint256 _wethAmount) internal returns (uint256 amountOut) {
        // TODO: amount out min
        uint256 amountOutMin = 0;

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(asset),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _wethAmount,
            amountOutMinimum: amountOutMin,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(params);
    }
}
