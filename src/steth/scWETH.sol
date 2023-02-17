// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

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
import {IMarkets} from "../interfaces/euler/IMarkets.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";

error InvalidEthWstEthMaxLtv();
error InvalidBorrowPercentLtv();
error InvalidFlashLoanCaller();
error InvalidSlippageTolerance();
error AdminZeroAddress();

contract scWETH is sc4626, IFlashLoanRecipient {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    address public constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;

    // The Euler market contract
    IMarkets public constant markets = IMarkets(0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3);

    // Euler supply token for wstETH (ewstETH)
    IEulerEToken public constant eToken = IEulerEToken(0xbd1bd5C956684f7EB79DA40f582cbE1373A1D593);

    // Euler debt token for WETH (dWETH)
    IEulerDToken public constant dToken = IEulerDToken(0x62e28f054efc24b26A794F5C1249B6349454352C);

    // Curve pool for ETH-stETH
    ICurvePool public constant curvePool = ICurvePool(0xDC24316b9AE028F1497c275EB9192a3Ea0f67022);

    // Lido staking contract (stETH)
    ILido public constant stEth = ILido(0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84);

    IwstETH public constant wstETH = IwstETH(0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0);
    WETH public constant weth = WETH(payable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2));

    // Chainlink pricefeed (stETH -> ETH)
    AggregatorV3Interface public constant stEThToEthPriceFeed =
        AggregatorV3Interface(0x86392dC19c0b719886221c78AB11eb8Cf5c52812);

    // Balancer vault for flashloans
    IVault public constant balancerVault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    // total invested during last harvest/rebalance
    uint256 public totalInvested;

    // total profit generated for this vault
    uint256 public totalProfit;

    // loan to value(ltv) ratio for borrowing eth on euler with wsteth
    // as collateral for the flashloan
    uint256 public ethWstEthMaxLtv;

    // percentage of the ethWstEthMaxLtv at which we borrow for the
    // flashloan
    uint256 public borrowPercentLtv;

    // slippage for curve swaps
    uint256 public slippageTolerance;

    constructor(address _admin, uint256 _ethWstEthMaxLtv, uint256 _borrowPercentLtv, uint256 _slippageTolerance)
        sc4626(_admin, ERC20(address(weth)), "Sandclock WETH Vault", "scWETH")
    {
        if (_admin == address(0)) revert AdminZeroAddress();
        if (_ethWstEthMaxLtv > 1e18) revert InvalidEthWstEthMaxLtv();
        if (_borrowPercentLtv > 1e18) revert InvalidBorrowPercentLtv();
        if (_slippageTolerance > 1e18) revert InvalidSlippageTolerance();

        ethWstEthMaxLtv = _ethWstEthMaxLtv;
        borrowPercentLtv = _borrowPercentLtv;
        slippageTolerance = _slippageTolerance;

        ERC20(address(stEth)).safeApprove(address(wstETH), type(uint256).max);
        ERC20(address(stEth)).safeApprove(address(curvePool), type(uint256).max);
        ERC20(address(wstETH)).safeApprove(EULER, type(uint256).max);
        ERC20(address(weth)).safeApprove(EULER, type(uint256).max);
        // Enter the euler collateral market (collateral's address, *not* the eToken address) ,
        markets.enterMarket(0, address(wstETH));
    }

    /////////////////// ADMIN/KEEPER METHODS //////////////////////////////////

    function harvest() external onlyRole(KEEPER_ROLE) {
        // store the old total
        uint256 oldTotalInvested = totalInvested;

        totalInvested = totalAssets();

        // profit since last harvest, zero if there was a loss
        uint256 profit = totalInvested > oldTotalInvested ? totalInvested - oldTotalInvested : 0;
        totalProfit += profit;

        uint256 fee = profit.mulWadDown(performanceFee);

        // mint equivalent amount of tokens to the performance fee beneficiary ie the treasury
        _mint(treasury, fee.mulDivDown(1e18, convertToAssets(1e18)));
    }

    // separate to save gas for users depositing
    function depositIntoStrategy() external onlyRole(KEEPER_ROLE) {
        _depositIntoStrategy();
    }

    /// @param amount : amount of asset to withdraw into the vault
    function withdrawToVault(uint256 amount) external onlyRole(KEEPER_ROLE) {
        _withdrawToVault(amount);
    }

    //////////////////// VIEW METHODS //////////////////////////

    function totalAssets() public view override returns (uint256 assets) {
        // value of the supplied collateral in eth terms using chainlink oracle
        assets = totalCollateralSupplied();

        // add float
        assets += asset.balanceOf(address(this));

        // subtract the debt
        assets -= totalDebt();
    }

    // total wstETH supplied as collateral (in ETH terms)
    function totalCollateralSupplied() public view returns (uint256) {
        return _wstEthToEth(eToken.balanceOfUnderlying(address(this)));
    }

    // total eth borrowed
    function totalDebt() public view returns (uint256) {
        return dToken.balanceOf(address(this));
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
    function receiveFlashLoan(address[] memory, uint256[] memory amounts, uint256[] memory, bytes memory userData)
        external
    {
        if (msg.sender != address(balancerVault)) {
            revert InvalidFlashLoanCaller();
        }

        // the amount flashloaned
        uint256 flashLoanAmount = amounts[0];

        // decode user data
        (bool deposit, uint256 amount) = abi.decode(userData, (bool, uint256));

        amount += flashLoanAmount;

        // if flashloan received as part of a deposit
        if (deposit) {
            // unwrap eth
            weth.withdraw(amount);

            // stake to lido / eth => stETH
            stEth.submit{value: amount}(address(0x00));

            // wrap stETH
            wstETH.wrap(stEth.balanceOf(address(this)));

            // add wstETH liquidity on Euler
            eToken.deposit(0, type(uint256).max);

            // borrow enough weth from Euler to payback flashloan
            dToken.borrow(0, flashLoanAmount);
        }
        // if flashloan received as part of a withdrawal
        else {
            // repay debt + withdraw collateral
            if (flashLoanAmount >= totalDebt()) {
                dToken.repay(0, type(uint256).max);
                eToken.withdraw(0, type(uint256).max);
            } else {
                dToken.repay(0, flashLoanAmount);
                eToken.withdraw(0, _ethToWstEth(amount));
            }

            // unwrap wstETH
            uint256 stEthAmount = wstETH.unwrap(wstETH.balanceOf(address(this)));

            // stETH to eth
            curvePool.exchange(1, 0, stEthAmount, stEthAmount.mulWadDown(slippageTolerance));

            // wrap eth
            weth.deposit{value: address(this).balance}();
        }

        // payback flashloan
        asset.safeTransfer(address(balancerVault), flashLoanAmount);
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
        uint256 flashLoanAmount = (amount * ltv) / (1e18 - ltv);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;

        // take flashloan
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(true, amount));

        // needed otherwise counted as profit during harvest
        totalInvested += amount;
    }

    function _withdrawToVault(uint256 amount) internal {
        // calculate the amount of weth that you have to flashloan to repay in order to withdraw 'amount' wstEth(collateral)
        uint256 flashLoanAmount = amount.mulWadDown(getLeverage() - 1e18);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;

        // take flashloan
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(false, amount));
    }

    function _wstEthToEth(uint256 wstEthAmount) internal view returns (uint256 ethAmount) {
        if (wstEthAmount > 0) {
            // wstETh to stEth using exchangeRate
            uint256 stEthAmount = wstETH.getStETHByWstETH(wstEthAmount);

            // stEth to eth
            (, int256 price,,,) = stEThToEthPriceFeed.latestRoundData();
            ethAmount = stEthAmount.mulWadDown(uint256(price));
        }
    }

    function _ethToWstEth(uint256 ethAmount) internal view returns (uint256 wstEthAmount) {
        if (ethAmount > 0) {
            (, int256 price,,,) = stEThToEthPriceFeed.latestRoundData();

            // eth to stEth
            uint256 stEthAmount = ethAmount.divWadDown(uint256(price));

            // stEth to wstEth
            wstEthAmount = wstETH.getWstETHByStETH(stEthAmount);
        }
    }

    function afterDeposit(uint256, uint256) internal override {}

    function beforeWithdraw(uint256 assets, uint256) internal override {
        uint256 float = asset.balanceOf(address(this));
        if (assets <= float) {
            return;
        }

        uint256 missing = assets - float;

        // needed otherwise counted as loss during harvest
        totalInvested -= missing;

        _withdrawToVault(missing);
    }
}
