// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {sc4626} from "../sc4626.sol";
import {IFlashLoan} from "../interfaces/euler/IFlashLoan.sol";
import {IEulerDToken} from "../interfaces/euler/IEulerDToken.sol";
import {IEulerEToken} from "../interfaces/euler/IEulerEToken.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {ILido} from "../interfaces/lido/ILido.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IMarkets} from "../interfaces/euler/IMarkets.sol";
import {ICurveExchange} from "../interfaces/curve/ICurveExchange.sol";

error scWETH__InvalidEthWstEthMaxLtv();
error scWETH__InvalidBorrowPercentLtv();
error scWETH__InvalidFlashloanCaller();
error scWETH_InvalidSlippageTolerance();

// TODO:
// Functions for leveraging up and leveraging down

// Taking flasloan from Euler
contract scWETH is sc4626, IFlashLoan {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    using FixedPointMathLib for uint256;

    enum FlashLoanType {
        Deposit,
        Withdraw
    }

    struct FlashLoanParams {
        FlashLoanType flashLoanType;
        uint256 flashLoanAmount;
        uint256 amount; // this can we the withdraw or deposit amount
        bool swapOnCurve;
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
    ICurveExchange public constant curveExchange =
        ICurveExchange(0x81C46fECa27B31F3ADC2b91eE4be9717d1cd3DD7);
    ILido public constant stEth =
        ILido(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    IwstETH public constant wstETH =
        IwstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

    WETH public constant weth =
        WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    // uint256 public totalInvested;
    // uint256 public totalProfit;
    // ltv for borrowing eth on euler with wsteth as collateral for the flashloan
    uint256 public ethWstEthMaxLtv; // 100% = 1e18
    // percentage of the ethWstEthMaxLtv at which we borrow (100% means we borrow at max ltv) for the flashloan
    uint256 public borrowPercentLtv; // (1e18 = 100%)
    uint256 public slippageTolerance; // (1e18 = 100%)

    constructor(
        uint256 _ethWstEthMaxLtv,
        uint256 _borrowPercentLtv,
        uint256 _slippageTolerance
    ) sc4626(ERC20(address(weth)), "Sandclock WETH Vault", "scWETH") {
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
    function depositIntoStrategy(bool swapOnCurve)
        external
        onlyRole(KEEPER_ROLE)
    {
        _depositIntoStrategy(swapOnCurve);
    }

    /// @param amount : amount of asset to withdraw into the vault
    function withdrawToVault(uint256 amount) external onlyRole(KEEPER_ROLE) {
        _withdrawToVault(amount);
    }

    //////////////////// VIEW METHODS //////////////////////////

    function totalAssets() public view override returns (uint256 assets) {
        return totalCollateralSupplied() - totalDebt();
    }

    // total wstETH supplied as collateral (in ETH terms)
    function totalCollateralSupplied() public view returns (uint256) {
        uint256 collateralWstETH = eTokenwstETH.balanceOfUnderlying(
            address(this)
        );

        // wstETh to stEth using exchangeRate
        uint256 collateralstEth = wstETH.getStETHByWstETH(collateralWstETH);

        // stEth to eth using curve
        // TODO: use chainlink oracle
        return
            curveExchange.get_exchange_amount(
                address(curvePool),
                address(stEth),
                address(weth),
                collateralstEth
            );
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
    function onFlashLoan(bytes memory data) external {
        if (msg.sender != EULER) revert scWETH__InvalidFlashloanCaller();
        FlashLoanParams memory params = abi.decode(data, (FlashLoanParams));

        if (params.flashLoanType == FlashLoanType.Deposit) {
            uint256 depositAmount = params.flashLoanAmount + params.amount;
            // weth to eth
            weth.withdraw(depositAmount);
            if (params.swapOnCurve) {
                // eth to steth
                curvePool.exchange{value: depositAmount}(
                    0,
                    1,
                    depositAmount,
                    depositAmount // we want to have atleast 1:1 eth/stEth
                );
            } else {
                // stake to lido
                stEth.submit{value: depositAmount}(address(0x00));
            }

            uint256 stEthBalance = stEth.balanceOf(address(this));
            // wrap to wstEth
            wstETH.wrap(stEthBalance);

            // add wstETH Liquidity on Euler
            eTokenwstETH.deposit(0, type(uint256).max);

            // borrow enough weth from Euler to payback flashloan
            dTokenWeth.borrow(0, params.flashLoanAmount);
        } else if (params.flashLoanType == FlashLoanType.Withdraw) {
            // repay debt
            dTokenWeth.repay(0, params.flashLoanAmount);

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
        weth.safeTransfer(EULER, params.flashLoanAmount);
    }

    // need to be able to receive eth
    receive() external payable {}

    //////////////////// INTERNAL METHODS //////////////////////////

    // @dev: the ltv at which we to take a flashloan
    function _flashloanLtv() internal view returns (uint256) {
        return ethWstEthMaxLtv.mulWadDown(borrowPercentLtv);
    }

    function _depositIntoStrategy(bool swapOnCurve) internal {
        uint256 amount = asset.balanceOf(address(this));

        // calculate optimum weth to flashloan
        uint256 ltv = _flashloanLtv();
        uint256 flashLoanAmount = (amount * ltv) / (WAD - ltv);

        FlashLoanParams memory params = FlashLoanParams(
            FlashLoanType.Deposit,
            flashLoanAmount,
            amount,
            swapOnCurve
        );

        // take flash loan
        dTokenWeth.flashLoan(flashLoanAmount, abi.encode(params));
    }

    function _withdrawToVault(uint256 amount) internal {
        // calculate the amount of weth that you have to flashloan to repay in order to withdraw 'amount' wstEth(collateral)
        uint256 flashLoanAmount = amount.mulWadDown(getLeverage() - 1);

        FlashLoanParams memory params = FlashLoanParams(
            FlashLoanType.Withdraw,
            flashLoanAmount,
            amount,
            true
        );

        // take flashloan
        dTokenWeth.flashLoan(flashLoanAmount, abi.encode(params));
    }

    function _calcMinDy(uint256 amount) internal view returns (uint256) {
        return amount.mulWadDown(slippageTolerance);
    }

    function afterDeposit(uint256, uint256) internal override {}

    function beforeWithdraw(uint256 assets, uint256) internal override {
        _withdrawToVault(assets);
    }
}
