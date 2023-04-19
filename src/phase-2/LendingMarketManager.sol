// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {IEulerDToken, IEulerEToken, IEulerMarkets} from "lib/euler-interfaces/contracts/IEuler.sol";

import {Constants as C} from "../lib/Constants.sol";
import {sc4626} from "../sc4626.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {ILido} from "../interfaces/lido/ILido.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";

abstract contract LendingMarketManager {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    enum LendingMarketType {
        AAVE_V3,
        EULER
    }

    struct LendingMarket {
        function(uint256) supply;
        function(uint256) borrow;
        function(uint256) repay;
        function(uint256) withdraw;
        function() view returns(uint256) getCollateral;
        function() view returns(uint256) getDebt;
    }

    // Lido staking contract (stETH)
    ILido public immutable stEth;

    IwstETH public immutable wstETH;
    WETH public immutable weth;

    // Chainlink pricefeed (stETH -> ETH)
    AggregatorV3Interface public stEThToEthPriceFeed;

    // Curve pool for ETH-stETH
    ICurvePool public immutable curvePool;
    // Balancer vault for flashloans
    IVault public immutable balancerVault;

    // mapping from lending market id to protocol params
    mapping(LendingMarketType => LendingMarket) lendingMarkets;

    constructor(
        ILido _stEth,
        IwstETH _wstEth,
        WETH _weth,
        AggregatorV3Interface _stEthToEthPriceFeed,
        ICurvePool _curvePool,
        IVault _balancerVault
    ) {
        stEth = _stEth;
        wstETH = _wstEth;
        weth = _weth;
        stEThToEthPriceFeed = _stEthToEthPriceFeed;
        curvePool = _curvePool;
        balancerVault = _balancerVault;

        ERC20(address(stEth)).safeApprove(address(wstETH), type(uint256).max);
        ERC20(address(stEth)).safeApprove(address(curvePool), type(uint256).max);
        ERC20(address(wstETH)).safeApprove(C.AAVE_POOL, type(uint256).max);
        ERC20(address(weth)).safeApprove(C.AAVE_POOL, type(uint256).max);
        ERC20(address(wstETH)).safeApprove(C.EULER, type(uint256).max);

        // Enter the euler collateral market (collateral's address, *not* the eToken address) ,
        IEulerMarkets(C.EULER_MARKETS).enterMarket(0, address(wstETH));
        // set e-mode on aave-v3 for increased borrowing capacity to 90% of collateral
        IPool(C.AAVE_POOL).setUserEMode(C.AAVE_EMODE_ID);

        lendingMarkets[LendingMarketType.AAVE_V3] = LendingMarket(
            supplyWstEthAAVEV3,
            borrowWethAAVEV3,
            repayWethAAVEV3,
            withdrawWstEthAAVEV3,
            getCollateralAAVEV3,
            getDebtAAVEV3
        );

        lendingMarkets[LendingMarketType.EULER] = LendingMarket(
            supplyWstEthEuler, borrowWethEuler, repayWethEuler, withdrawWstEthEuler, getCollateralEuler, getDebtEuler
        );
    }

    // number of lending markets we are currently using
    function totalMarkets() internal pure returns (uint256) {
        return uint256(type(LendingMarketType).max) + 1;
    }

    function allocationPercent(LendingMarketType market) external view returns (uint256) {
        return lendingMarkets[market].getCollateral().divWadDown(totalCollateral());
    }

    /// @notice returns the total wstETH supplied as collateral (in ETH)
    function totalCollateral() public view virtual returns (uint256);

    /// @notice returns the total ETH borrowed
    function totalDebt() public view virtual returns (uint256);

    //////////////////////////     AAVE V3 ///////////////////////////////
    function supplyWstEthAAVEV3(uint256 amount) internal {
        IPool(C.AAVE_POOL).supply(address(wstETH), _ethToWstEth(amount), address(this), 0);
    }

    function borrowWethAAVEV3(uint256 amount) internal {
        IPool(C.AAVE_POOL).borrow(address(weth), amount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
    }

    function repayWethAAVEV3(uint256 amount) internal {
        IPool(C.AAVE_POOL).repay(address(weth), amount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
    }

    function withdrawWstEthAAVEV3(uint256 amount) internal {
        IPool(C.AAVE_POOL).withdraw(address(wstETH), _ethToWstEth(amount), address(this));
    }

    function getCollateralAAVEV3() internal view returns (uint256) {
        return _wstEthToEth(IAToken(C.AAVE_AWSTETH_TOKEN).balanceOf(address(this)));
    }

    function getDebtAAVEV3() internal view returns (uint256) {
        return ERC20(C.AAVAAVE_VAR_DEBT_WETH_TOKEN).balanceOf(address(this));
    }

    ///////////////////////////////// EULER /////////////////////////////////

    function supplyWstEthEuler(uint256 amount) internal {
        IEulerEToken(C.EULER_ETOKEN_WSTETH).deposit(0, _ethToWstEth(amount));
    }

    function borrowWethEuler(uint256 amount) internal {
        IEulerDToken(C.EULER_DTOKEN_WETH).borrow(0, amount);
    }

    function repayWethEuler(uint256 amount) internal {
        IEulerDToken(C.EULER_DTOKEN_WETH).repay(0, amount);
    }

    function withdrawWstEthEuler(uint256 amount) internal {
        IEulerEToken(C.EULER_ETOKEN_WSTETH).withdraw(0, _ethToWstEth(amount));
    }

    function getCollateralEuler() internal view returns (uint256) {
        return _wstEthToEth(IEulerEToken(C.EULER_ETOKEN_WSTETH).balanceOfUnderlying(address(this)));
    }

    function getDebtEuler() internal view returns (uint256) {
        return IEulerDToken(C.EULER_DTOKEN_WETH).balanceOf(address(this));
    }

    //////////////////////// ORACLE METHODS ///////////////////////////////

    function _ethToWstEth(uint256 ethAmount) internal view returns (uint256 wstEthAmount) {
        if (ethAmount > 0) {
            (, int256 price,,,) = stEThToEthPriceFeed.latestRoundData();

            // eth to stEth
            uint256 stEthAmount = ethAmount.divWadDown(uint256(price));

            // stEth to wstEth
            wstEthAmount = wstETH.getWstETHByStETH(stEthAmount);
        }
    }

    function _stEthToEth(uint256 stEthAmount) internal view returns (uint256 ethAmount) {
        if (stEthAmount > 0) {
            // stEth to eth
            (, int256 price,,,) = stEThToEthPriceFeed.latestRoundData();
            ethAmount = stEthAmount.mulWadDown(uint256(price));
        }
    }

    function _wstEthToEth(uint256 wstEthAmount) internal view returns (uint256 ethAmount) {
        // wstETh to stEth using exchangeRate
        uint256 stEthAmount = wstETH.getStETHByWstETH(wstEthAmount);
        ethAmount = _stEthToEth(stEthAmount);
    }
}
