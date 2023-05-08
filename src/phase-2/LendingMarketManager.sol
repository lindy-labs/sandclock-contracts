// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console.sol";

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
import {IComet} from "../interfaces/compound-v3/IComet.sol";

abstract contract LendingMarketManager {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    enum LendingMarketType {
        AAVE_V3,
        EULER,
        COMPOUND_V3
    }

    struct LendingMarket {
        function(uint256) supply;
        function(uint256) borrow;
        function(uint256) repay;
        function(uint256) withdraw;
        function() view returns(uint256) getCollateral;
        function() view returns(uint256) getDebt;
        function() view returns(uint) getMaxLtv;
    }

    struct AaveV3 {
        address pool;
        address aWstEth;
        address varDWeth;
    }

    struct Euler {
        address protocol;
        address markets;
        address eWstEth;
        address dWeth;
    }

    struct Compound {
        address comet;
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

    IPool aaveV3pool;
    IAToken aaveV3aWstEth;
    ERC20 aaveV3varDWeth;

    address public immutable eulerProtocol;
    IEulerMarkets public immutable eulerMarkets;
    IEulerEToken public immutable eulerEWstEth;
    IEulerDToken public immutable eulerDWeth;

    IComet public immutable compoundV3Comet;

    // mapping from lending market id to protocol params
    mapping(LendingMarketType => LendingMarket) lendingMarkets;

    constructor(
        ILido _stEth,
        IwstETH _wstEth,
        WETH _weth,
        AggregatorV3Interface _stEthToEthPriceFeed,
        ICurvePool _curvePool,
        IVault _balancerVault,
        AaveV3 memory aaveV3,
        Euler memory euler,
        Compound memory compound
    ) {
        stEth = _stEth;
        wstETH = _wstEth;
        weth = _weth;
        stEThToEthPriceFeed = _stEthToEthPriceFeed;
        curvePool = _curvePool;
        balancerVault = _balancerVault;

        aaveV3pool = IPool(aaveV3.pool);
        aaveV3aWstEth = IAToken(aaveV3.aWstEth);
        aaveV3varDWeth = ERC20(aaveV3.varDWeth);

        eulerProtocol = euler.protocol;
        eulerMarkets = IEulerMarkets(euler.markets);
        eulerEWstEth = IEulerEToken(euler.eWstEth);
        eulerDWeth = IEulerDToken(euler.dWeth);

        compoundV3Comet = IComet(compound.comet);

        ERC20(address(stEth)).safeApprove(address(wstETH), type(uint256).max);
        ERC20(address(stEth)).safeApprove(address(curvePool), type(uint256).max);
        ERC20(address(wstETH)).safeApprove(aaveV3.pool, type(uint256).max);
        ERC20(address(weth)).safeApprove(aaveV3.pool, type(uint256).max);
        ERC20(address(wstETH)).safeApprove(euler.protocol, type(uint256).max);
        ERC20(address(weth)).safeApprove(euler.protocol, type(uint256).max);
        ERC20(address(wstETH)).safeApprove(compound.comet, type(uint256).max);
        ERC20(address(weth)).safeApprove(compound.comet, type(uint256).max);

        // Enter the euler collateral market (collateral's address, *not* the eToken address) ,
        IEulerMarkets(euler.markets).enterMarket(0, address(wstETH));
        // set e-mode on aave-v3 for increased borrowing capacity to 90% of collateral
        IPool(aaveV3.pool).setUserEMode(C.AAVE_EMODE_ID);

        lendingMarkets[LendingMarketType.AAVE_V3] = LendingMarket(
            supplyWstEthAAVEV3,
            borrowWethAAVEV3,
            repayWethAAVEV3,
            withdrawWstEthAAVEV3,
            getCollateralAAVEV3,
            getDebtAAVEV3,
            maxLtvAAVEV3
        );

        lendingMarkets[LendingMarketType.EULER] = LendingMarket(
            supplyWstEthEuler,
            borrowWethEuler,
            repayWethEuler,
            withdrawWstEthEuler,
            getCollateralEuler,
            getDebtEuler,
            maxLtvEuler
        );

        lendingMarkets[LendingMarketType.COMPOUND_V3] = LendingMarket(
            supplyWstEthCompound,
            borrowWethCompound,
            repayWethCompound,
            withdrawWstEthCompound,
            getCollateralCompound,
            getDebtCompound,
            maxLtvCompound
        );
    }

    // number of lending markets we are currently using
    function totalMarkets() internal pure returns (uint256) {
        return uint256(type(LendingMarketType).max) + 1;
    }

    function getDebt(LendingMarketType market) public view returns (uint256) {
        return lendingMarkets[market].getDebt();
    }

    /// @dev in terms of weth
    function getCollateral(LendingMarketType market) public view returns (uint256) {
        return _wstEthToEth(lendingMarkets[market].getCollateral());
    }

    function getLtv(LendingMarketType market) public view returns (uint256) {
        return getDebt(market).divWadDown(getCollateral(market));
    }

    function getMaxLtv(LendingMarketType market) public view returns (uint256) {
        return lendingMarkets[market].getMaxLtv();
    }

    /// @notice method to get the assets deposited in a particular lending market
    function getAssets(LendingMarketType market) external view returns (uint256) {
        return getCollateral(market) - getDebt(market);
    }

    ////////////////////////// AAVE V3 ///////////////////////////////
    ///  @notice supply wstETH to AAVE V3
    /// @param amount amount of wstETH to supply
    function supplyWstEthAAVEV3(uint256 amount) internal {
        IPool(aaveV3pool).supply(address(wstETH), amount, address(this), 0);
    }

    function borrowWethAAVEV3(uint256 amount) internal {
        IPool(aaveV3pool).borrow(address(weth), amount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
    }

    function repayWethAAVEV3(uint256 amount) internal {
        IPool(aaveV3pool).repay(address(weth), amount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
    }

    /// @notice withdraw wstETH from AAVE V3
    /// @param amount amount of wstETH to withdraw
    function withdrawWstEthAAVEV3(uint256 amount) internal {
        IPool(aaveV3pool).withdraw(address(wstETH), amount, address(this));
    }

    function getCollateralAAVEV3() internal view returns (uint256) {
        return IAToken(aaveV3aWstEth).balanceOf(address(this));
    }

    function getDebtAAVEV3() internal view returns (uint256) {
        return ERC20(aaveV3varDWeth).balanceOf(address(this));
    }

    function maxLtvAAVEV3() internal view returns (uint256) {
        return uint256(aaveV3pool.getEModeCategoryData(C.AAVE_EMODE_ID).ltv) * 1e14;
    }

    ///////////////////////////////// EULER /////////////////////////////////

    function supplyWstEthEuler(uint256 amount) internal {
        IEulerEToken(eulerEWstEth).deposit(0, amount);
    }

    function borrowWethEuler(uint256 amount) internal {
        IEulerDToken(eulerDWeth).borrow(0, amount);
    }

    function repayWethEuler(uint256 amount) internal {
        IEulerDToken(eulerDWeth).repay(0, amount);
    }

    function withdrawWstEthEuler(uint256 amount) internal {
        IEulerEToken(eulerEWstEth).withdraw(0, amount);
    }

    function getCollateralEuler() internal view returns (uint256) {
        return IEulerEToken(eulerEWstEth).balanceOfUnderlying(address(this));
    }

    function getDebtEuler() internal view returns (uint256) {
        return IEulerDToken(eulerDWeth).balanceOf(address(this));
    }

    function maxLtvEuler() internal view returns (uint256) {
        uint256 collateralFactor = eulerMarkets.underlyingToAssetConfig(address(wstETH)).collateralFactor;
        uint256 borrowFactor = eulerMarkets.underlyingToAssetConfig(address(weth)).borrowFactor;

        uint256 scaledCollateralFactor = collateralFactor.divWadDown(C.EULER_CONFIG_FACTOR_SCALE);
        uint256 scaledBorrowFactor = borrowFactor.divWadDown(C.EULER_CONFIG_FACTOR_SCALE);

        return scaledCollateralFactor.mulWadDown(scaledBorrowFactor);
    }

    //////////////////////// Compound V3 ////////////////////////////////
    function supplyWstEthCompound(uint256 amount) internal {
        compoundV3Comet.supply(address(wstETH), amount);
    }

    function borrowWethCompound(uint256 amount) internal {
        compoundV3Comet.withdraw(address(weth), amount);
    }

    function repayWethCompound(uint256 amount) internal {
        compoundV3Comet.supply(address(weth), amount);
    }

    function withdrawWstEthCompound(uint256 amount) internal {
        compoundV3Comet.withdraw(address(wstETH), amount);
    }

    function getCollateralCompound() internal view returns (uint256) {
        return compoundV3Comet.userCollateral(address(this), address(wstETH)).balance;
    }

    function getDebtCompound() internal view returns (uint256) {
        return compoundV3Comet.borrowBalanceOf(address(this));
    }

    function maxLtvCompound() internal view returns (uint256) {
        return compoundV3Comet.getAssetInfoByAddress(address(wstETH)).borrowCollateralFactor;
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
