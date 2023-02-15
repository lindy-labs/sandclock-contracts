// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {sc4626} from "../sc4626.sol";
import {IEulerDToken} from "../interfaces/euler/IEulerDToken.sol";
import {IEulerEToken} from "../interfaces/euler/IEulerEToken.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {ILido} from "../interfaces/lido/ILido.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IMarkets} from "../interfaces/euler/IMarkets.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";

error scWETH__InvalidEthWstEthMaxLtv();
error scWETH__InvalidBorrowPercentLtv();
error scWETH__InvalidFlashloanCaller();
error scWETH_InvalidSlippageTolerance();
error scWETH_StrategyAdminCannotBe0Address();

// TODO:
// Functions for leveraging up and leveraging down

// Taking flasloan from Euler
contract scWETH is sc4626, IFlashLoanRecipient {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    using FixedPointMathLib for uint256;

    enum FlashLoanType {
        Deposit,
        Withdraw
    }

    struct FlashLoanParams {
        FlashLoanType flashLoanType;
        uint256 amount; // this can we the withdraw or deposit amount
    }

    uint256 internal constant WAD = 1e18; // The scalar of ETH and most ERC20s.
    address public constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;

    IMarkets public constant markets =
        IMarkets(0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3);
    IEulerEToken public constant eTokenwstETH =
        IEulerEToken(0xbd1bd5C956684f7EB79DA40f582cbE1373A1D593); // the token whose underlying is supplied as collateral
    IEulerDToken public constant dTokenWeth =
        IEulerDToken(0x62e28f054efc24b26A794F5C1249B6349454352C); // the token whose underlying we are borrowing
    ICurvePool public constant curvePool =
        ICurvePool(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    // ICurveExchange public constant curveExchange =
    //     ICurveExchange(0x81C46fECa27B31F3ADC2b91eE4be9717d1cd3DD7);
    ILido public constant stEth =
        ILido(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    IwstETH public constant wstETH =
        IwstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    WETH public constant weth =
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));
    AggregatorV3Interface public constant stEThToEthPriceFeed =
        AggregatorV3Interface(0x86392dC19c0b719886221c78AB11eb8Cf5c52812);
    IVault public constant balancerVault =
        IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    // uint256 public totalInvested;
    // uint256 public totalProfit;
    // ltv for borrowing eth on euler with wsteth as collateral for the flashloan
    uint256 public ethWstEthMaxLtv; // 100% = 1e18
    // percentage of the ethWstEthMaxLtv at which we borrow (100% means we borrow at max ltv) for the flashloan
    uint256 public borrowPercentLtv; // (1e18 = 100%)
    uint256 public slippageTolerance; // (1e18 = 100%)

    constructor(
        address _admin,
        uint256 _ethWstEthMaxLtv,
        uint256 _borrowPercentLtv,
        uint256 _slippageTolerance
    ) sc4626(_admin, ERC20(address(weth)), "Sandclock WETH Vault", "scWETH") {
        if (_admin == address(0)) revert scWETH_StrategyAdminCannotBe0Address();
        if (_ethWstEthMaxLtv > WAD) revert scWETH__InvalidEthWstEthMaxLtv();
        if (_borrowPercentLtv > WAD) revert scWETH__InvalidBorrowPercentLtv();
        if (_slippageTolerance > WAD) revert scWETH_InvalidSlippageTolerance();

        ethWstEthMaxLtv = _ethWstEthMaxLtv;
        borrowPercentLtv = _borrowPercentLtv;
        slippageTolerance = _slippageTolerance;

        ERC20(address(stEth)).safeApprove(address(wstETH), type(uint256).max);
        ERC20(address(stEth)).safeApprove(
            address(curvePool),
            type(uint256).max
        );
        ERC20(address(wstETH)).safeApprove(EULER, type(uint256).max);
        // Enter the euler collateral market (collateral's address, *not* the eToken address) ,
        markets.enterMarket(0, address(wstETH));
    }

    /////////////////// ADMIN/KEEPER METHODS //////////////////////////////////

    function harvest() external onlyRole(KEEPER_ROLE) {}

    // this is only separate to save
    // gas for users depositing, ultimately controlled by float %
    function depositIntoStrategy() external onlyRole(KEEPER_ROLE) {
        _depositIntoStrategy();
    }

    /// @param amount : amount of asset to withdraw into the vault
    function withdrawToVault(uint256 amount) external onlyRole(KEEPER_ROLE) {
        _withdrawToVault(amount);
    }

    //////////////////// VIEW METHODS //////////////////////////

    function totalAssets() public view override returns (uint256 assets) {
        return
            weth.balanceOf(address(this)) +
            totalCollateralSupplied() -
            totalDebt();
    }

    // total wstETH supplied as collateral (in ETH terms)
    function totalCollateralSupplied() public view returns (uint256 value) {
        uint256 collateralWstETH = eTokenwstETH.balanceOfUnderlying(
            address(this)
        );

        if (collateralWstETH > 0) {
            // wstETh to stEth using exchangeRate
            uint256 collateralstEth = wstETH.getStETHByWstETH(collateralWstETH);

            // stEth to eth
            (, int256 price, , , ) = stEThToEthPriceFeed.latestRoundData();
            value = collateralstEth.mulWadDown(uint256(price));
        }
    }

    // total eth borrowed
    function totalDebt() public view returns (uint256) {
        return dTokenWeth.balanceOf(address(this));
    }

    // returns the net leverage that the strategy is using right now (1e18 = 100%)
    function getLeverage() public view returns (uint256) {
        return totalCollateralSupplied().divWadUp(totalAssets());
    }

    // returns the net LTV at which we have borrowed till now (1e18 = 100%)
    function getLtv() public view returns (uint256) {
        // totalDebt / totalSupplied
        return totalDebt().divWadUp(totalCollateralSupplied());
    }

    //////////////////// EXTERNAL METHODS //////////////////////////

    // called after the flashLoan on _depositIntoStrategy
    function receiveFlashLoan(
        IERC20[] memory,
        uint256[] memory amounts,
        uint256[] memory,
        bytes memory userData
    ) external {
        if (msg.sender != address(balancerVault))
            revert scWETH__InvalidFlashloanCaller();

        uint256 flashLoanAmount = amounts[0];

        FlashLoanParams memory params = abi.decode(userData, (FlashLoanParams));

        if (params.flashLoanType == FlashLoanType.Deposit) {
            uint256 depositAmount = flashLoanAmount + params.amount;
            // weth to eth
            weth.withdraw(depositAmount);

            // stake to lido / eth => stETH
            stEth.submit{value: depositAmount}(address(0x00));

            // console2.log("amount", params.amount);
            // console2.log("depositAmount", depositAmount);
            // console2.log("steth balance", stEth.balanceOf(address(this)));

            // wrap to wstEth
            wstETH.wrap(stEth.balanceOf(address(this)));

            // add wstETH Liquidity on Euler
            eTokenwstETH.deposit(0, type(uint256).max);

            // borrow enough weth from Euler to payback flashloan
            dTokenWeth.borrow(0, flashLoanAmount);
        } else if (params.flashLoanType == FlashLoanType.Withdraw) {
            // repay debt
            dTokenWeth.repay(0, flashLoanAmount);

            // withdraw amount wstEth(collateral)
            eTokenwstETH.withdraw(0, params.amount);

            // wstETH to stEth
            uint256 stEthAmount = wstETH.unwrap(params.amount);

            // stETH to eth
            curvePool.exchange(1, 0, stEthAmount, _calcMinDy(stEthAmount));

            // eth to weth
            weth.deposit{value: address(this).balance}();
        }

        // payback flashloan
        weth.safeTransfer(address(balancerVault), flashLoanAmount);
    }

    // need to be able to receive eth
    receive() external payable {}

    //////////////////// INTERNAL METHODS //////////////////////////

    // @dev: the ltv at which we to take a flashloan
    function _flashloanLtv() internal view returns (uint256) {
        return ethWstEthMaxLtv.mulWadDown(borrowPercentLtv);
    }

    function _depositIntoStrategy() internal {
        uint256 amount = asset.balanceOf(address(this));

        // calculate optimum weth to flashloan
        uint256 ltv = _flashloanLtv();
        uint256 flashLoanAmount = (amount * ltv) / (WAD - ltv);

        FlashLoanParams memory params = FlashLoanParams(
            FlashLoanType.Deposit,
            amount
        );

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(weth));

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;

        // take flash loan
        balancerVault.flashLoan(this, tokens, amounts, abi.encode(params));
    }

    function _withdrawToVault(uint256 amount) internal {
        // calculate the amount of weth that you have to flashloan to repay in order to withdraw 'amount' wstEth(collateral)
        uint256 flashLoanAmount = amount.mulWadDown(getLeverage() - 1e18);

        FlashLoanParams memory params = FlashLoanParams(
            FlashLoanType.Withdraw,
            amount
        );

        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(address(weth));

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;

        // take flash loan
        balancerVault.flashLoan(this, tokens, amounts, abi.encode(params));
    }

    function _calcMinDy(uint256 amount) internal view returns (uint256) {
        return amount.mulWadDown(slippageTolerance);
    }

    function afterDeposit(uint256, uint256) internal override {}

    function beforeWithdraw(uint256 assets, uint256) internal override {
        _withdrawToVault(assets);
    }
}
