// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.10;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IMarkets} from "../interfaces/euler/IMarkets.sol";
import {IEulerEulDistributor} from "../interfaces/euler/IEulerEulDistributor.sol";

import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IEulerDToken} from "../interfaces/euler/IEulerDToken.sol";
import {IEulerEToken} from "../interfaces/euler/IEulerEToken.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {sc4626} from "../sc4626.sol";

import "forge-std/console2.sol";

contract scUSDC is sc4626 {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    error StrategyEULSwapFailed();

    WETH public constant weth =
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    ERC20 public constant USDC =
        ERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);

    address public constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;

    // EUL token
    ERC20 eul = ERC20(0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b);

    // EUL distributor
    IEulerEulDistributor eulDistributor =
        IEulerEulDistributor(0xd524E29E3BAF5BB085403Ca5665301E94387A7e2);

    uint256 public totalInvested;
    uint256 public totalProfit;

    ERC4626 public scWETH;

    // The Euler market contract
    IMarkets public constant markets =
        IMarkets(0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3);

    // Euler supply token for USDC
    IEulerEToken public constant eToken =
        IEulerEToken(0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716);

    // Euler debt token for WETH (dWETH)
    IEulerDToken public constant dToken =
        IEulerDToken(0x62e28f054efc24b26A794F5C1249B6349454352C);

    // 0x swap router
    address xrouter = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    // Chainlink pricefeed (stETH -> ETH)
    AggregatorV3Interface public constant usdcToEthPriceFeed =
        AggregatorV3Interface(0x986b5E1e1755e3C2440e960477f25201B0a8bbD4);

    uint256 public immutable usdcWethMaxLtv = 0.81e18;

    constructor(
        address _admin,
        ERC20 _usdc,
        ERC4626 _scWETH
    ) sc4626(_admin, _usdc, "Sandclock USDC Vault", "scUSDC") {
        scWETH = _scWETH;
        _usdc.approve(EULER, type(uint).max);
        weth.approve(address(_scWETH), type(uint).max);

        markets.enterMarket(0, address(_usdc));
    }

    // need to be able to receive eth rewards
    receive() external payable {}

    function totalAssets() public view override returns (uint256 assets) {
        uint256 collateral = eToken.balanceOfUnderlying(address(this));
        uint256 wethDebt = dToken.balanceOf(address(this));
        (, int256 usdcPriceInWeth, , , ) = usdcToEthPriceFeed.latestRoundData();

        uint256 debtInUsdc = getUsdcFromWeth(
            wethDebt,
            uint256(usdcPriceInWeth)
        );

        uint256 wethInvested = scWETH.convertToAssets(
            scWETH.balanceOf(address(this))
        );
        uint256 investedInUsdc = getUsdcFromWeth(
            wethInvested,
            uint256(usdcPriceInWeth)
        );

        assets = collateral + investedInUsdc - debtInUsdc;
    }

    function getUsdcFromWeth(
        uint256 _wethAmount,
        uint256 _usdcPriceInWeth
    ) public pure returns (uint256) {
        return (_wethAmount * 1e18) / uint256(_usdcPriceInWeth) / 1e12;
    }

    function getWethFromUsdc(
        uint256 _usdcAmount,
        uint256 _usdcPriceInWeth
    ) public pure returns (uint256) {
        return ((_usdcAmount * 1e12) * uint256(_usdcPriceInWeth)) / 1e18;
    }

    function afterDeposit(uint256, uint256) internal override {}

    function beforeWithdraw(uint256 assets, uint256 shares) internal override {
        uint256 usdcBalance = asset.balanceOf(address(this));

        console2.log("usdcBalance", usdcBalance);

        if (usdcBalance > assets) return;

        uint256 usdcToWithdrawFromStrategy = assets - usdcBalance;
        // TODO: withdraw from strategy

        (, int256 usdcPriceInWeth, , , ) = usdcToEthPriceFeed.latestRoundData();

        uint256 wethNeeded = getWethFromUsdc(
            usdcToWithdrawFromStrategy,
            uint256(usdcPriceInWeth)
        );

        scWETH.withdraw(
            scWETH.convertToShares(wethNeeded),
            address(this),
            address(this)
        );

        console2.log("wethNeeded", wethNeeded);
        console2.log("assets withdrawn", assets);
        console2.log("end usdcBalance", asset.balanceOf(address(this)));
    }

    // @dev: access control not needed, this is only separate to save
    // gas for users depositing, ultimately controlled by float %
    function depositIntoStrategy() external {
        _depositIntoStrategy();
    }

    function _depositIntoStrategy() internal {
        (, int256 usdcPriceInWeth, , , ) = usdcToEthPriceFeed.latestRoundData();
        uint256 currentLtv = getLtv();
        console2.log("currentLtv", currentLtv);
        if (currentLtv == 0) currentLtv = usdcWethMaxLtv;

        console2.log("currentLtv", currentLtv);

        // supply usdc to euler
        uint256 usdcBalance = asset.balanceOf(address(this));
        eToken.deposit(0, usdcBalance);

        console2.log("usdcBalance", usdcBalance);
        console2.log("usdcPriceInWeth", uint256(usdcPriceInWeth));
        console2.log(
            "getWethFromUsdc(usdcBalance, uint256(usdcPriceInWeth))",
            getWethFromUsdc(usdcBalance, uint256(usdcPriceInWeth))
        );
        // // borrow weth from euler
        uint256 wethToBorrow = (currentLtv *
            getWethFromUsdc(usdcBalance, uint256(usdcPriceInWeth))) / 1e18;

        console2.log("wethToBorrow", wethToBorrow);

        dToken.borrow(0, wethToBorrow);

        // // supply weth to scWETH
        scWETH.deposit(wethToBorrow, address(this));

        console2.log("ltv", getLtv());
    }

    // total wstETH supplied as collateral (in ETH terms)
    function totalCollateralSupplied() public view returns (uint256) {
        return eToken.balanceOfUnderlying(address(this));
    }

    // total eth borrowed
    function totalDebt() public view returns (uint256) {
        return dToken.balanceOf(address(this));
    }

    // returns the net LTV at which we have borrowed till now (1e18 = 100%)
    function getLtv() public view returns (uint256) {
        if (totalDebt() == 0) return 0;

        uint256 debt = dToken.balanceOf(address(this));

        (, int256 usdcPriceInWeth, , , ) = usdcToEthPriceFeed.latestRoundData();
        uint256 debtPriceInUsdc = getUsdcFromWeth(
            debt,
            uint256(usdcPriceInWeth)
        );

        // totalDebt / totalSupplied
        return debtPriceInUsdc.divWadUp(totalCollateralSupplied());
    }

    function harvest(
        uint256 _claimable,
        bytes32[] calldata _proof,
        uint256 _eulAmount,
        bytes calldata _eulSwapData
    ) external onlyRole(KEEPER_ROLE) {
        // claim EUL rewards
        eulDistributor.claim(
            address(this),
            address(eul),
            _claimable,
            _proof,
            address(0)
        );

        // swap EUL -> WETH
        if (_eulAmount > 0) {
            eul.safeApprove(xrouter, _eulAmount);
            (bool success, ) = xrouter.call{value: 0}(_eulSwapData);
            if (!success) revert StrategyEULSwapFailed();
        }

        // reinvest
        _depositIntoStrategy();
    }
}
