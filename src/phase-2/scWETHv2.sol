// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console.sol";

import {
    InvalidTargetLtv,
    ZeroAddress,
    InvalidSlippageTolerance,
    PleaseUseRedeemMethod,
    InvalidFlashLoanCaller,
    InvalidAllocationPercents,
    InsufficientDepositBalance,
    FloatBalanceTooSmall
} from "../errors/scErrors.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IEulerMarkets} from "lib/euler-interfaces/contracts/IEuler.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";

import {Constants as C} from "../lib/Constants.sol";
import {sc4626} from "../sc4626.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {ILido} from "../interfaces/lido/ILido.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";
import {LendingMarketManager} from "./LendingMarketManager.sol";

contract scWETHv2 is sc4626, IFlashLoanRecipient {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    event SlippageToleranceUpdated(address indexed admin, uint256 newSlippageTolerance);
    event ExchangeProxyAddressUpdated(address indexed user, address newAddress);
    event NewTargetLtvApplied(address indexed admin, uint256 newTargetLtv);
    event Harvest(uint256 profitSinceLastHarvest, uint256 performanceFee);
    event Invested(uint256 amount, SupplyBorrowParam[] supplyBorrowParams);
    event DisInvested(RepayWithdrawParam[] repayWithdrawParams);
    event Reallocated(RepayWithdrawParam[] from, SupplyBorrowParam[] to);
    event TokensSwapped(address inToken, address outToken, uint256 amountIn, uint256 amountOutMin);

    struct RebalanceParams {
        RepayWithdrawParam[] repayWithdrawParams;
        SupplyBorrowParam[] supplyBorrowParams;
        uint256 wstEthSwapAmount; // amount of wstEth to swap to weth (0 = not required, type(uint).max = all wstEth Balance)
        uint256 wethSwapAmount; //  amount of weth to swap to wstEth (0 = not required)
    }

    struct RepayWithdrawParam {
        LendingMarketManager.Protocol protocol;
        uint256 repayAmount; // flashLoanAmount (in WETH)
        uint256 withdrawAmount; // amount of wstEth to withdraw from the market (amount + flashLoanAmount) (in wstEth)
    }

    struct SupplyBorrowParam {
        LendingMarketManager.Protocol protocol;
        uint256 supplyAmount; // amount of wstEth to supply to the market (in wstEth)
        uint256 borrowAmount; // flashLoanAmount (in WETH)
    }

    struct ConstructorParams {
        address admin;
        address keeper;
        uint256 slippageTolerance;
        address weth;
        address stEth;
        address wstEth;
        ICurvePool curvePool;
        IVault balancerVault;
        AggregatorV3Interface stEthToEthPriceFeed;
        LendingMarketManager lendingManager;
    }

    ILido public immutable stEth;
    IwstETH public immutable wstETH;
    WETH public immutable weth;

    // total invested during last harvest/rebalance
    uint256 public totalInvested;

    // total profit generated for this vault
    uint256 public totalProfit;

    // slippage for curve swaps
    uint256 public slippageTolerance;
    LendingMarketManager public immutable lendingManager;

    // Curve pool for ETH-stETH
    ICurvePool public immutable curvePool;
    // Balancer vault for flashloans
    IVault public immutable balancerVault;
    // Chainlink pricefeed (stETH -> ETH)
    AggregatorV3Interface public stEThToEthPriceFeed;

    constructor(ConstructorParams memory params)
        sc4626(params.admin, params.keeper, ERC20(params.weth), "Sandclock WETH Vault v2", "scWETHv2")
    {
        if (params.slippageTolerance > C.ONE) revert InvalidSlippageTolerance();
        slippageTolerance = params.slippageTolerance;
        curvePool = params.curvePool;
        balancerVault = params.balancerVault;
        stEThToEthPriceFeed = params.stEthToEthPriceFeed;
        stEth = ILido(params.stEth);
        wstETH = IwstETH(params.wstEth);
        weth = WETH(payable(params.weth));

        lendingManager = params.lendingManager;

        address aaveV3Pool = address(lendingManager.aaveV3pool());
        address eulerProtocol = lendingManager.eulerProtocol();
        address compoundComet = address(lendingManager.compoundV3Comet());

        ERC20(params.stEth).safeApprove(params.wstEth, type(uint256).max);
        ERC20(params.stEth).safeApprove(address(curvePool), type(uint256).max);
        ERC20(params.wstEth).safeApprove(aaveV3Pool, type(uint256).max);
        ERC20(params.weth).safeApprove(aaveV3Pool, type(uint256).max);
        ERC20(params.wstEth).safeApprove(eulerProtocol, type(uint256).max);
        ERC20(params.weth).safeApprove(eulerProtocol, type(uint256).max);
        ERC20(params.wstEth).safeApprove(compoundComet, type(uint256).max);
        ERC20(params.weth).safeApprove(compoundComet, type(uint256).max);

        // Enter the euler collateral market (collateral's address, *not* the eToken address) ,
        IEulerMarkets(address(lendingManager.eulerMarkets())).enterMarket(0, params.wstEth);
        // set e-mode on aave-v3 for increased borrowing capacity to 90% of collateral
        IPool(aaveV3Pool).setUserEMode(C.AAVE_EMODE_ID);
    }

    /// @notice set the slippage tolerance for curve swaps
    /// @param newSlippageTolerance the new slippage tolerance
    /// @dev slippage tolerance is a number between 0 and 1e18
    function setSlippageTolerance(uint256 newSlippageTolerance) external {
        onlyAdmin();
        if (newSlippageTolerance > C.ONE) revert InvalidSlippageTolerance();
        slippageTolerance = newSlippageTolerance;
        emit SlippageToleranceUpdated(msg.sender, newSlippageTolerance);
    }

    /// @notice set stEThToEthPriceFeed address
    /// @param newAddress the new address of the stEThToEthPriceFeed
    function setStEThToEthPriceFeed(address newAddress) external {
        onlyAdmin();
        if (newAddress == address(0)) revert ZeroAddress();
        stEThToEthPriceFeed = AggregatorV3Interface(newAddress);
    }

    /////////////////// ADMIN/KEEPER METHODS //////////////////////////////////

    /// @dev to be used to ideally swap euler rewards to weth
    /// @dev can also be used to swap between other tokens
    function swapTokens(
        bytes calldata swapData,
        address inToken,
        address outToken,
        uint256 amountIn,
        uint256 amountOutMin
    ) external {
        onlyKeeper();
        (bool success, bytes memory result) = address(lendingManager).delegatecall(
            abi.encodeWithSelector(
                LendingMarketManager.swapTokens.selector, swapData, inToken, outToken, amountIn, amountOutMin
            )
        );
        if (!success) revert(string(result));

        (amountIn, amountOutMin) = abi.decode(result, (uint256, uint256));

        emit TokensSwapped(inToken, outToken, amountIn, amountOutMin);
    }

    /// @notice invest funds into the strategy and harvest profits if any
    /// @dev for the first deposit, deposits everything into the strategy.
    /// @dev also mints performance fee tokens to the treasury
    function investAndHarvest(uint256 totalInvestAmount, SupplyBorrowParam[] calldata supplyBorrowParams) external {
        onlyKeeper();
        invest(totalInvestAmount, supplyBorrowParams);

        // store the old total
        uint256 oldTotalInvested = totalInvested;
        uint256 assets = totalCollateral() - totalDebt();

        if (assets > oldTotalInvested) {
            totalInvested = assets;

            // profit since last harvest, zero if there was a loss
            uint256 profit = assets - oldTotalInvested;
            totalProfit += profit;

            uint256 fee = profit.mulWadDown(performanceFee);

            // mint equivalent amount of tokens to the performance fee beneficiary ie the treasury
            _mint(treasury, convertToShares(fee));

            emit Harvest(profit, fee);
        }
    }

    /// @notice withdraw funds from the strategy into the vault
    /// @param amount : amount of assets to withdraw into the vault
    function withdrawToVault(uint256 amount) external {
        onlyKeeper();
        _withdrawToVault(amount);
    }

    /// @notice invest funds into the strategy (or reinvesting profits)
    /// @param totalInvestAmount : amount of weth to invest into the strategy
    /// @param supplyBorrowParams : protocols to invest into and their respective amounts
    function invest(uint256 totalInvestAmount, SupplyBorrowParam[] calldata supplyBorrowParams) internal {
        if (totalInvestAmount > asset.balanceOf(address(this))) revert InsufficientDepositBalance();

        uint256 totalFlashLoanAmount;
        for (uint256 i; i < supplyBorrowParams.length; i++) {
            totalFlashLoanAmount += supplyBorrowParams[i].borrowAmount;
        }

        RebalanceParams memory params = RebalanceParams({
            repayWithdrawParams: new RepayWithdrawParam[](0),
            supplyBorrowParams: supplyBorrowParams,
            wstEthSwapAmount: 0,
            wethSwapAmount: totalInvestAmount + totalFlashLoanAmount
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalFlashLoanAmount;

        // needed otherwise counted as profit during harvest
        totalInvested += totalInvestAmount;

        _initiateFlashLoan();
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(params));
        _finalizeFlashLoan();

        emit Invested(totalInvestAmount, supplyBorrowParams);
    }

    /// @notice disinvest from lending markets in case of a loss
    /// @param repayWithdrawParams : protocols to disinvest from and their respective amounts
    function disinvest(RepayWithdrawParam[] calldata repayWithdrawParams) external {
        onlyKeeper();
        uint256 totalFlashLoanAmount;
        for (uint256 i; i < repayWithdrawParams.length; i++) {
            totalFlashLoanAmount += repayWithdrawParams[i].repayAmount;
        }

        RebalanceParams memory params = RebalanceParams({
            repayWithdrawParams: repayWithdrawParams,
            supplyBorrowParams: new SupplyBorrowParam[](0),
            wstEthSwapAmount: type(uint256).max,
            wethSwapAmount: 0
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalFlashLoanAmount;

        // take flashloan
        _initiateFlashLoan();
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(params));
        _finalizeFlashLoan();

        emit DisInvested(repayWithdrawParams);
    }

    /// @notice reallocate funds between protocols (without any slippage)
    // @param wstEthSwapAmount: amount of wstEth to swap to weth
    function reallocate(
        RepayWithdrawParam[] calldata from,
        SupplyBorrowParam[] calldata to,
        uint256 wstEthSwapAmount,
        uint256 wethSwapAmount
    ) external {
        onlyKeeper();
        uint256 totalFlashLoanAmount;
        for (uint256 i; i < from.length; i++) {
            totalFlashLoanAmount += from[i].repayAmount;
        }

        RebalanceParams memory params = RebalanceParams({
            repayWithdrawParams: from,
            supplyBorrowParams: to,
            wstEthSwapAmount: wstEthSwapAmount,
            wethSwapAmount: wethSwapAmount
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalFlashLoanAmount;

        // take flashloan
        _initiateFlashLoan();
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(params));
        _finalizeFlashLoan();

        emit Reallocated(from, to);
    }

    //////////////////// VIEW METHODS //////////////////////////

    /// @notice returns the total assets (WETH) held by the strategy
    function totalAssets() public view override returns (uint256 assets) {
        // value of the supplied collateral in eth terms using chainlink oracle
        assets = totalCollateral();

        // subtract the debt
        assets -= totalDebt();

        // add float
        assets += asset.balanceOf(address(this));
    }

    /// @notice returns the total assets supplied as collateral (in WETH terms)
    function totalCollateral() public view returns (uint256) {
        return wstEthToEth(lendingManager.getTotalCollateral(address(this)));
    }

    /// @notice returns the total ETH borrowed
    function totalDebt() public view returns (uint256) {
        return lendingManager.getTotalDebt(address(this));
    }

    //////////////////// EXTERNAL METHODS //////////////////////////

    /// @notice helper method to directly deposit ETH instead of weth
    function deposit(address receiver) external payable returns (uint256 shares) {
        uint256 assets = msg.value;

        // Check for rounding error since we round down in previewDeposit.
        require((shares = previewDeposit(assets)) != 0, "ZERO_SHARES");

        // wrap eth
        weth.deposit{value: assets}();

        _mint(receiver, shares);

        emit Deposit(msg.sender, receiver, assets, shares);

        afterDeposit(assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        if (msg.sender != owner) {
            uint256 allowed = allowance[owner][msg.sender]; // Saves gas for limited approvals.

            if (allowed != type(uint256).max) allowance[owner][msg.sender] = allowed - shares;
        }

        // Check for rounding error since we round down in previewRedeem.
        require((assets = previewRedeem(shares)) != 0, "ZERO_ASSETS");

        beforeWithdraw(assets, shares);

        _burn(owner, shares);

        uint256 balance = asset.balanceOf(address(this));

        if (assets > balance) {
            assets = balance;
        }

        emit Withdraw(msg.sender, receiver, owner, assets, shares);

        asset.safeTransfer(receiver, assets);
    }

    function withdraw(uint256, address, address) public virtual override returns (uint256) {
        revert PleaseUseRedeemMethod();
    }

    /// @dev called after the flashLoan on rebalance
    function receiveFlashLoan(address[] memory, uint256[] memory amounts, uint256[] memory, bytes memory userData)
        external
    {
        if (msg.sender != address(balancerVault)) {
            revert InvalidFlashLoanCaller();
        }

        _isFlashLoanInitiated();

        // the amount flashloaned
        uint256 flashLoanAmount = amounts[0];

        // decode user data
        (RebalanceParams memory rebalanceParams) = abi.decode(userData, (RebalanceParams));

        // repay and withdraw first
        _repayWithdraw(rebalanceParams.repayWithdrawParams);

        if (rebalanceParams.wstEthSwapAmount != 0) {
            // unwrap wstETH
            uint256 stEthAmount = wstETH.unwrap(
                rebalanceParams.wstEthSwapAmount == type(uint256).max
                    ? wstETH.balanceOf(address(this))
                    : rebalanceParams.wstEthSwapAmount
            );
            // stETH to eth
            curvePool.exchange(1, 0, stEthAmount, _stEthToEth(stEthAmount).mulWadDown(slippageTolerance));
            // wrap eth
            weth.deposit{value: address(this).balance}();
        }

        if (rebalanceParams.wethSwapAmount != 0) {
            // unwrap eth
            weth.withdraw(rebalanceParams.wethSwapAmount);
            // stake to lido / eth => stETH
            // todo: since we are directly depositing to lido for stEth
            // we are getting a slightly lower rate than the rate calculated from the
            // chainlink oracle on _ethToWstEth method.
            stEth.submit{value: rebalanceParams.wethSwapAmount}(address(0x00));

            // wrap stETH
            wstETH.wrap(stEth.balanceOf(address(this)));
        }

        _supplyBorrow(rebalanceParams.supplyBorrowParams);

        // payback flashloan
        asset.safeTransfer(address(balancerVault), flashLoanAmount);

        _enforceFloat();
    }

    // need to be able to receive eth
    receive() external payable {}

    //////////////////// INTERNAL METHODS //////////////////////////

    function _calcFlashLoanAmountWithdrawing(
        LendingMarketManager.Protocol protocol,
        uint256 totalAmount,
        uint256 totalInvested_
    ) internal view returns (uint256 flashLoanAmount, uint256 amount) {
        uint256 debt = lendingManager.getDebt(protocol, address(this));
        uint256 assets = wstEthToEth(lendingManager.getCollateral(protocol, address(this))) - debt;
        // withdraw from each protocol based on the allocation percent
        amount = totalAmount.mulDivDown(assets, totalInvested_);

        // calculate the flashloan amount needed
        flashLoanAmount = amount.mulDivDown(debt, assets);
    }

    function _withdrawToVault(uint256 amount) internal {
        uint256 n = lendingManager.totalMarkets();
        uint256 flashLoanAmount;
        RepayWithdrawParam[] memory repayWithdrawParams = new RepayWithdrawParam[](n);

        uint256 totalInvested_ = totalCollateral() - totalDebt();

        {
            uint256 flashLoanAmount_;
            uint256 amount_;
            for (uint256 i; i < n; i++) {
                (flashLoanAmount_, amount_) =
                    _calcFlashLoanAmountWithdrawing(LendingMarketManager.Protocol(i), amount, totalInvested_);

                repayWithdrawParams[i] = RepayWithdrawParam(
                    LendingMarketManager.Protocol(i), flashLoanAmount_, _ethToWstEth(flashLoanAmount_ + amount_)
                );
                flashLoanAmount += flashLoanAmount_;
            }
        }

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;

        // needed otherwise counted as loss during harvest
        totalInvested -= amount;

        SupplyBorrowParam[] memory empty;
        RebalanceParams memory params = RebalanceParams(repayWithdrawParams, empty, type(uint256).max, 0);

        // take flashloan
        _initiateFlashLoan();
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(params));
        _finalizeFlashLoan();
    }

    function _supplyBorrow(SupplyBorrowParam[] memory params) internal {
        uint256 n = params.length;
        if (n != 0) {
            for (uint256 i; i < n; i++) {
                _lendingManagerDelegateCall(
                    LendingMarketManager.supply.selector, params[i].protocol, params[i].supplyAmount
                ); // supplyAmount must be in wstEth
                _lendingManagerDelegateCall(
                    LendingMarketManager.borrow.selector, params[i].protocol, params[i].borrowAmount
                ); // borrowAmount must be in weth
            }
        }
    }

    function _repayWithdraw(RepayWithdrawParam[] memory params) internal {
        uint256 n = params.length;
        if (n != 0) {
            for (uint256 i; i < n; i++) {
                if (params[i].repayAmount > lendingManager.getDebt(params[i].protocol, address(this))) {
                    _lendingManagerDelegateCall(
                        LendingMarketManager.repay.selector, params[i].protocol, type(uint256).max
                    );
                    _lendingManagerDelegateCall(
                        LendingMarketManager.withdraw.selector, params[i].protocol, type(uint256).max
                    );
                } else {
                    _lendingManagerDelegateCall(
                        LendingMarketManager.repay.selector, params[i].protocol, params[i].repayAmount
                    ); // repayAmount must be in weth
                    _lendingManagerDelegateCall(
                        LendingMarketManager.withdraw.selector, params[i].protocol, params[i].withdrawAmount
                    ); // withdrawAmount must be in wstEth
                }
            }
        }
    }

    /// @dev Need to use "delegatecall" to interact with lending protocols through the lending manager contract.
    function _lendingManagerDelegateCall(bytes4 _selector, LendingMarketManager.Protocol _protocolId, uint256 _amount)
        internal
    {
        (bool success, bytes memory result) =
            address(lendingManager).delegatecall(abi.encodeWithSelector(_selector, _protocolId, _amount));

        if (!success) revert(string(result));
    }

    /// @notice enforce float to be above the minimum required
    function _enforceFloat() internal view {
        uint256 float = asset.balanceOf(address(this));
        uint256 floatRequired = minimumFloatAmount;
        if (float < floatRequired) {
            revert FloatBalanceTooSmall(float, floatRequired);
        }
    }

    function beforeWithdraw(uint256 assets, uint256) internal override {
        uint256 float = asset.balanceOf(address(this));
        if (assets <= float) {
            return;
        }

        uint256 minimumFloat = minimumFloatAmount;
        uint256 floatRequired = float < minimumFloat ? minimumFloat - float : 0;
        uint256 missing = assets + floatRequired - float;

        _withdrawToVault(missing);
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

    function wstEthToEth(uint256 wstEthAmount) public view returns (uint256 ethAmount) {
        // wstETh to stEth using exchangeRate
        uint256 stEthAmount = wstETH.getStETHByWstETH(wstEthAmount);
        ethAmount = _stEthToEth(stEthAmount);
    }
}

// todo:
// euler rewards & 0x swapping
// gas optimizations
// call with nenad to make contract function signatures similar
