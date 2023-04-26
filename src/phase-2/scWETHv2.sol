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
    InsufficientDepositBalance
} from "../errors/scErrors.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {Constants as C} from "../lib/Constants.sol";
import {sc4626} from "../sc4626.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {ILido} from "../interfaces/lido/ILido.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";
import {LendingMarketManager} from "./LendingMarketManager.sol";

contract scWETHv2 is sc4626, LendingMarketManager, IFlashLoanRecipient {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    event SlippageToleranceUpdated(address indexed admin, uint256 newSlippageTolerance);
    event ExchangeProxyAddressUpdated(address indexed user, address newAddress);
    event NewTargetLtvApplied(address indexed admin, uint256 newTargetLtv);
    event Harvest(uint256 profitSinceLastHarvest, uint256 performanceFee);

    struct RebalanceParams {
        RepayWithdrawParam[] repayWithdrawParams;
        SupplyBorrowParam[] supplyBorrowParams;
        bool doWstEthToWethSwap; // if true wstEth will be swapped to eth after weth repay and wstEth Withdraw
        bool doWethToWstEthSwap; // if true weth will be swapped to wstEth before wstEth supply and weth borrow
        uint256 wethSwapAmount; // if doWethToWstEthSwap is true, amount of weth to swap to wstEth
    }

    struct RepayWithdrawParam {
        LendingMarketType market;
        uint256 repayAmount; // flashLoanAmount (in WETH)
        uint256 withdrawAmount; // amount of wstEth to withdraw from the market (amount + flashLoanAmount) (in wstEth)
    }

    struct SupplyBorrowParam {
        LendingMarketType market;
        uint256 supplyAmount; // amount of wstEth to supply to the market (in wstEth)
        uint256 borrowAmount; // flashLoanAmount (in WETH)
    }

    struct ConstructorParams {
        address admin;
        address keeper;
        uint256 slippageTolerance;
        ICurvePool curveEthStEthPool;
        ILido stEth;
        IwstETH wstEth;
        WETH weth;
        AggregatorV3Interface stEthToEthPriceFeed;
        IVault balancerVault;
    }

    // total invested during last harvest/rebalance
    uint256 public totalInvested;

    // total profit generated for this vault
    uint256 public totalProfit;

    // slippage for curve swaps
    uint256 public slippageTolerance;

    constructor(ConstructorParams memory _params)
        sc4626(_params.admin, _params.keeper, _params.weth, "Sandclock WETH Vault v2", "scWETHv2")
        LendingMarketManager(
            _params.stEth,
            _params.wstEth,
            _params.weth,
            _params.stEthToEthPriceFeed,
            _params.curveEthStEthPool,
            _params.balancerVault
        )
    {
        if (_params.slippageTolerance > C.ONE) revert InvalidSlippageTolerance();
        slippageTolerance = _params.slippageTolerance;
    }

    /// @notice set the slippage tolerance for curve swaps
    /// @param newSlippageTolerance the new slippage tolerance
    /// @dev slippage tolerance is a number between 0 and 1e18
    function setSlippageTolerance(uint256 newSlippageTolerance) external onlyAdmin {
        if (newSlippageTolerance > C.ONE) revert InvalidSlippageTolerance();
        slippageTolerance = newSlippageTolerance;
        emit SlippageToleranceUpdated(msg.sender, newSlippageTolerance);
    }

    /// @notice set stEThToEthPriceFeed address
    /// @param newAddress the new address of the stEThToEthPriceFeed
    function setStEThToEthPriceFeed(address newAddress) external onlyAdmin {
        if (newAddress == address(0)) revert ZeroAddress();
        stEThToEthPriceFeed = AggregatorV3Interface(newAddress);
    }

    /////////////////// ADMIN/KEEPER METHODS //////////////////////////////////

    /// @notice harvest profits and rebalance the position by investing profits back into the strategy
    /// @dev for the first deposit, deposits everything into the strategy.
    /// @dev reduces the getLtv() back to the target ltv
    /// @dev also mints performance fee tokens to the treasury
    function harvest(SupplyBorrowParam[] calldata supplyBorrowParams) external {
        // reinvest
        // todo: use float here instead of full asset balance
        invest(asset.balanceOf(address(this)), supplyBorrowParams);

        // store the old total
        uint256 oldTotalInvested = totalInvested;
        uint256 assets = totalAssets();

        // todo: harvest euler rewards

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
    function withdrawToVault(uint256 amount) external onlyKeeper {
        _withdrawToVault(amount);
    }

    /// @notice invest funds into the strategy (or reinvesting profits)
    /// @param totalInvestAmount : amount of weth to invest into the strategy
    /// @param supplyBorrowParams : protocols to invest into and their respective amounts
    function invest(uint256 totalInvestAmount, SupplyBorrowParam[] calldata supplyBorrowParams) public onlyKeeper {
        if (totalInvestAmount > asset.balanceOf(address(this))) revert InsufficientDepositBalance();

        uint256 totalFlashLoanAmount;
        for (uint256 i; i < supplyBorrowParams.length; i++) {
            totalFlashLoanAmount += supplyBorrowParams[i].borrowAmount;
        }

        RebalanceParams memory params = RebalanceParams({
            repayWithdrawParams: new RepayWithdrawParam[](0),
            supplyBorrowParams: supplyBorrowParams,
            doWstEthToWethSwap: false,
            doWethToWstEthSwap: true,
            wethSwapAmount: totalInvestAmount + totalFlashLoanAmount
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalFlashLoanAmount;

        // needed otherwise counted as profit during harvest
        totalInvested += totalInvestAmount;

        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(params));
    }

    /// @notice disinvest from lending markets in case of a loss
    /// @param repayWithdrawParams : protocols to disinvest from and their respective amounts
    function disinvest(RepayWithdrawParam[] calldata repayWithdrawParams) external onlyKeeper {
        uint256 totalFlashLoanAmount;
        for (uint256 i; i < repayWithdrawParams.length; i++) {
            totalFlashLoanAmount += repayWithdrawParams[i].repayAmount;
        }

        RebalanceParams memory params = RebalanceParams({
            repayWithdrawParams: repayWithdrawParams,
            supplyBorrowParams: new SupplyBorrowParam[](0),
            doWstEthToWethSwap: true,
            doWethToWstEthSwap: false,
            wethSwapAmount: 0
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalFlashLoanAmount;

        // take flashloan
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(params));
    }

    /// @notice reallocate funds from one protocol to another (without any slippage)
    function reallocate(RepayWithdrawParam[] calldata from, SupplyBorrowParam[] calldata to) external onlyKeeper {
        uint256 totalFlashLoanAmount;
        for (uint256 i; i < from.length; i++) {
            totalFlashLoanAmount += from[i].repayAmount;
        }

        RebalanceParams memory params = RebalanceParams({
            repayWithdrawParams: from,
            supplyBorrowParams: to,
            doWstEthToWethSwap: false,
            doWethToWstEthSwap: false,
            wethSwapAmount: 0
        });

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = totalFlashLoanAmount;

        // take flashloan
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(params));
    }

    // /// @dev ultimate method for rebalancing the position
    // function rebalance(uint256 totalFlashLoanAmount, RebalanceParams memory params) external onlyKeeper {
    //     // if (params.amount > asset.balanceOf(address(this))) revert InsufficientDepositBalance();

    //     address[] memory tokens = new address[](1);
    //     tokens[0] = address(weth);

    //     uint256[] memory amounts = new uint256[](1);
    //     amounts[0] = totalFlashLoanAmount;

    //     // take flashloan
    //     balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(params));
    // }

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

    /// @notice returns the net leverage that the strategy is using right now (1e18 = 100%)
    function getLeverage() public view returns (uint256) {
        uint256 coll = totalCollateral();
        return coll > 0 ? coll.divWadUp(coll - totalDebt()) : 0;
    }

    /// @notice returns the net LTV at which we have borrowed till now (1e18 = 100%)
    function getLtv() public view returns (uint256 ltv) {
        uint256 collateral = totalCollateral();
        if (collateral > 0) {
            // getDebt / totalSupplied
            ltv = totalDebt().divWadUp(collateral);
        }
    }

    function allocationPercent(LendingMarketType market) external view returns (uint256) {
        return (getCollateral(market) - getDebt(market)).divWadDown(totalInvested);
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

        // the amount flashloaned
        uint256 flashLoanAmount = amounts[0];

        // decode user data
        (RebalanceParams memory rebalanceParams) = abi.decode(userData, (RebalanceParams));

        // repay and withdraw first
        _repayWithdraw(rebalanceParams.repayWithdrawParams);

        if (rebalanceParams.doWstEthToWethSwap) {
            // unwrap wstETH
            uint256 stEthAmount = wstETH.unwrap(wstETH.balanceOf(address(this)));
            // stETH to eth
            curvePool.exchange(1, 0, stEthAmount, _stEthToEth(stEthAmount).mulWadDown(slippageTolerance));
            // wrap eth
            weth.deposit{value: address(this).balance}();
        }

        if (rebalanceParams.doWethToWstEthSwap) {
            // unwrap eth
            weth.withdraw(rebalanceParams.wethSwapAmount);
            // stake to lido / eth => stETH
            // todo: since we are directly depositing to lido for stEth
            // we are getting a slightly lower rate than the rate calculated from the
            // chainlink oracle on _ethToWstEth method.
            stEth.submit{value: rebalanceParams.wethSwapAmount}(address(0x00));

            // console.log("stEth balance: %s", stEth.balanceOf(address(this)));

            // wrap stETH
            wstETH.wrap(stEth.balanceOf(address(this)));
        }

        _supplyBorrow(rebalanceParams.supplyBorrowParams);

        // payback flashloan
        asset.safeTransfer(address(balancerVault), flashLoanAmount);
    }

    // need to be able to receive eth
    receive() external payable {}

    //////////////////// INTERNAL METHODS //////////////////////////

    function _calcFlashLoanAmountWithdrawing(LendingMarketType market, uint256 totalAmount, uint256 totalInvested_)
        internal
        view
        returns (uint256 flashLoanAmount, uint256 amount)
    {
        LendingMarket memory lendingMarket = lendingMarkets[market];
        uint256 debt = lendingMarket.getDebt();
        uint256 collateral = _wstEthToEth(lendingMarket.getCollateral());
        // withdraw from each protocol based on the allocation percent
        amount = totalAmount.mulDivDown(collateral - debt, totalInvested_);

        // calculate the flashloan amount needed
        flashLoanAmount = amount.mulDivDown(debt, collateral - debt);
    }

    function _withdrawToVault(uint256 amount) internal {
        uint256 n = totalMarkets();
        uint256 flashLoanAmount;
        RepayWithdrawParam[] memory repayWithdrawParams = new RepayWithdrawParam[](n);

        uint256 totalInvested_ = totalInvested;

        {
            uint256 flashLoanAmount_;
            uint256 amount_;
            for (uint256 i; i < n; i++) {
                (flashLoanAmount_, amount_) =
                    _calcFlashLoanAmountWithdrawing(LendingMarketType(i), amount, totalInvested_);

                repayWithdrawParams[i] = RepayWithdrawParam(LendingMarketType(i), amount_, flashLoanAmount_ + amount_);
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
        RebalanceParams memory params = RebalanceParams(repayWithdrawParams, empty, true, false, amount);

        // take flashloan
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(params));
    }

    function _supplyBorrow(SupplyBorrowParam[] memory supplyBorrowParams) internal {
        uint256 n = supplyBorrowParams.length;
        if (n != 0) {
            LendingMarket memory lendingMarket;
            for (uint256 i; i < n; i++) {
                lendingMarket = lendingMarkets[supplyBorrowParams[i].market];
                // console.log("supply Amount wstETH", _ethToWstEth(supplyBorrowParams[i].supplyAmount));
                // console.log("wstEth balance", wstETH.balanceOf(address(this)));
                lendingMarket.supply(supplyBorrowParams[i].supplyAmount);
                lendingMarket.borrow(supplyBorrowParams[i].borrowAmount);
                // console.log("borrow Amount", supplyBorrowParams[i].borrowAmount);
            }
        }
    }

    function _repayWithdraw(RepayWithdrawParam[] memory repayWithdrawParams) internal {
        // bool withdrawAll = flashLoanAmount >= totalDebt();
        uint256 n = repayWithdrawParams.length;
        if (n != 0) {
            LendingMarket memory lendingMarket;
            for (uint256 i; i < n; i++) {
                lendingMarket = lendingMarkets[repayWithdrawParams[i].market];
                if (repayWithdrawParams[i].repayAmount > lendingMarket.getDebt()) {
                    lendingMarket.repay(type(uint256).max);
                    lendingMarket.withdraw(type(uint256).max);
                } else {
                    console.log("to withdraw", _ethToWstEth(repayWithdrawParams[i].withdrawAmount));
                    console.log("market balance", lendingMarket.getCollateral());

                    lendingMarket.repay(repayWithdrawParams[i].repayAmount);
                    lendingMarket.withdraw(_ethToWstEth(repayWithdrawParams[i].withdrawAmount));
                }
            }
        }
    }

    function beforeWithdraw(uint256 assets, uint256) internal override {
        uint256 float = asset.balanceOf(address(this));
        if (assets <= float) {
            return;
        }

        uint256 missing = (assets - float);

        _withdrawToVault(missing);
    }
}
