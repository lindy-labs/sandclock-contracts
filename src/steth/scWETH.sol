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

error scWETH__InvalidEthWstEthMaxLtv();
error scWETH__InvalidBorrowPercentLtv();
error scWETH__InvalidFlashloanCaller();
error scWETH_InvalidSlippageTolerance();

// Taking flasloan from Euler
contract scWETH is sc4626, IFlashLoan {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    using FixedPointMathLib for uint256;

    enum FlashLoanType {
        Deposit,
        Withdraw
    }

    uint256 public constant MAX_BPS = 10000;
    address public constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;

    IMarkets public constant markets =
        IMarkets(0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3);
    IEulerEToken public constant eTokenwstETH =
        IEulerEToken(0xbd1bd5C956684f7EB79DA40f582cbE1373A1D593); // the token whose underlying is supplied as collateral
    IEulerDToken public constant dTokenWeth =
        IEulerDToken(0x62e28f054efc24b26A794F5C1249B6349454352C); // the token whose underlying we are borrowing
    ICurvePool public constant curve =
        ICurvePool(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);
    ILido public constant stEth =
        ILido(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);
    IwstETH public constant wstETH =
        IwstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);

    WETH public immutable weth;

    uint256 public totalInvested;
    uint256 public totalProfit;
    bool public swapOnCurve;
    // ltv for borrowing eth on euler with wsteth as collateral for the flashloan
    uint256 public ethWstEthMaxLtv; // in bps (10000 = 100%)
    // percentage of the ethWstEthMaxLtv at which we borrow (100% means we borrow at max ltv) for the flashloan
    uint256 public borrowPercentLtv; // in bps (10000 = 100%)
    uint256 public ethToStEthCurveSlippageTolerance; // in bps (10000 = 100%)

    constructor(
        ERC20 _weth,
        uint256 _ethWstEthMaxLtv,
        uint256 _borrowPercentLtv,
        uint256 _ethToStEthCurveSlippageTolerance
    ) sc4626(_weth, "Sandclock ETH Vault", "scETH") {
        if (_ethWstEthMaxLtv > MAX_BPS) revert scWETH__InvalidEthWstEthMaxLtv();
        if (_borrowPercentLtv > MAX_BPS)
            revert scWETH__InvalidBorrowPercentLtv();
        if (_ethToStEthCurveSlippageTolerance > MAX_BPS)
            revert scWETH_InvalidSlippageTolerance();

        swapOnCurve = true;
        ethWstEthMaxLtv = _ethWstEthMaxLtv;
        borrowPercentLtv = _borrowPercentLtv;
        ethToStEthCurveSlippageTolerance = _ethToStEthCurveSlippageTolerance;
        weth = WETH(payable(address(asset)));

        ERC20(address(stEth)).safeApprove(address(wstETH), type(uint256).max);
        ERC20(address(wstETH)).safeApprove(EULER, type(uint256).max);
        // Enter the euler collateral market (collateral's address, *not* the eToken address) ,
        markets.enterMarket(0, address(wstETH));
    }

    /////////////////// ADMIN/KEEPER METHODS //////////////////////////////////
    function setSwapOnCurve(bool _val) external onlyRole(KEEPER_ROLE) {
        swapOnCurve = _val;
    }

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

    // @dev: the actual ltv at which we borrow
    function flashloanLtv() public view returns (uint256) {
        return (ethWstEthMaxLtv * borrowPercentLtv) / 10000;
    }

    function totalAssets() public view override returns (uint256 assets) {
        assets = asset.balanceOf(address(this));
    }

    // returns the net leverage that the strategy is using right now
    function getLeverage() public view returns (uint256) {}

    // returns the net LTV at which we have borrowed till now
    function getLtv() public view returns (uint256) {}

    //////////////////// EXTERNAL METHODS //////////////////////////

    // called after the flashLoan on _depositIntoStrategy
    function onFlashLoan(bytes memory data) external {
        if (msg.sender != EULER) revert scWETH__InvalidFlashloanCaller();
        (
            uint256 bal,
            uint256 flashLoanAmount,
            FlashLoanType flashLoanType
        ) = abi.decode(data, (uint256, uint256, FlashLoanType));

        if (flashLoanType == FlashLoanType.Deposit) {
            uint256 depositAmount = flashLoanAmount + bal;
            // weth to eth
            weth.withdraw(depositAmount);
            if (swapOnCurve) {
                // eth to steth
                curve.exchange{value: depositAmount}(
                    0,
                    1,
                    depositAmount,
                    _calcMinSteth(
                        depositAmount,
                        ethToStEthCurveSlippageTolerance
                    )
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
            dTokenWeth.borrow(0, flashLoanAmount);
        } else if (flashLoanType == FlashLoanType.Withdraw) {}

        // payback flashloan
        weth.safeTransfer(EULER, flashLoanAmount);
    }

    // need to be able to receive eth
    receive() external payable {}

    //////////////////// INTERNAL METHODS //////////////////////////

    function _depositIntoStrategy() internal {
        uint256 bal = totalAssets();

        // calculate optimum weth to flashloan
        uint256 ltv = flashloanLtv();
        uint256 flashLoanAmount = (bal * ltv) / (MAX_BPS - ltv);

        // take flash loan
        dTokenWeth.flashLoan(
            flashLoanAmount,
            abi.encode(bal, flashLoanAmount, FlashLoanType.Deposit)
        );
    }

    function _withdrawToVault(uint256 amount) internal {
        // calculate the amount of weth that you have to flashloan to repay in order to withdraw 'amount' wstEth(collateral)
        // take flashloan
        // repay debt with flashloan
        // withdraw amount wstEth(collateral)
        // swap to Weth
    }

    function afterDeposit(uint256, uint256) internal override {}

    function beforeWithdraw(uint256, uint256) internal override {}

    function _calcMinSteth(uint256 _amount, uint256 _slippage)
        internal
        pure
        returns (uint256)
    {
        return (_amount * _slippage) / 10000;
    }
}
