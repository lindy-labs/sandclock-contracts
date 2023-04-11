// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {
    InvalidTargetLtv,
    ZeroAddress,
    InvalidSlippageTolerance,
    PleaseUseRedeemMethod,
    InvalidFlashLoanCaller
} from "../errors/scErrors.sol";

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

contract scWETH2 is sc4626, IFlashLoanRecipient {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    event SlippageToleranceUpdated(address indexed admin, uint256 newSlippageTolerance);
    event ExchangeProxyAddressUpdated(address indexed user, address newAddress);
    event NewTargetLtvApplied(address indexed admin, uint256 newTargetLtv);
    event Harvest(uint256 profitSinceLastHarvest, uint256 performanceFee);

    enum Protocol {
        AAVE_V3,
        EULER
    }

    struct FlashLoanParams {
        bool isDeposit;
        uint256 amount;
        uint256[] amounts; // amount to supply on each protocol in weth
        uint256[] flashLoanAmounts; // amount to borrow on each protocol in weth
    }

    struct ProtocolParams {
        uint128 allocationPercent; // uint256 maxLtv;
        uint128 targetLtv; // the target ltv ratio at which we actually borrow (<= maxLtv)
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
        ProtocolParams[] protocolParams;
    }

    // number of protocols to invest in
    uint256 public protocols;

    // mapping from protocol id to protocol params
    mapping(Protocol => ProtocolParams) public protocolParams;

    // Curve pool for ETH-stETH
    ICurvePool public immutable curvePool;

    // Lido staking contract (stETH)
    ILido public immutable stEth;

    IwstETH public immutable wstETH;
    WETH public immutable weth;

    // Chainlink pricefeed (stETH -> ETH)
    AggregatorV3Interface public stEThToEthPriceFeed;

    // Balancer vault for flashloans
    IVault public immutable balancerVault;

    // total invested during last harvest/rebalance
    uint256 public totalInvested;

    // total profit generated for this vault
    uint256 public totalProfit;

    // slippage for curve swaps
    uint256 public slippageTolerance;

    function _addProtocols(ProtocolParams[] memory params) internal {
        protocolParams[Protocol.AAVE_V3] = params[0];
        protocolParams[Protocol.EULER] = params[1];

        protocols += params.length;
    }

    constructor(ConstructorParams memory _params)
        sc4626(_params.admin, _params.keeper, _params.weth, "Sandclock WETH Vault", "scWETH")
    {
        if (_params.slippageTolerance > C.ONE) revert InvalidSlippageTolerance();

        curvePool = _params.curveEthStEthPool;
        stEth = _params.stEth;
        wstETH = _params.wstEth;
        weth = _params.weth;
        stEThToEthPriceFeed = _params.stEthToEthPriceFeed;
        balancerVault = _params.balancerVault;

        ERC20(address(stEth)).safeApprove(address(wstETH), type(uint256).max);
        ERC20(address(stEth)).safeApprove(address(curvePool), type(uint256).max);
        ERC20(address(wstETH)).safeApprove(C.AAVE_POOL, type(uint256).max);
        ERC20(address(weth)).safeApprove(C.AAVE_POOL, type(uint256).max);
        ERC20(address(wstETH)).safeApprove(C.EULER, type(uint256).max);

        // Enter the euler collateral market (collateral's address, *not* the eToken address) ,
        IEulerMarkets(C.EULER_MARKETS).enterMarket(0, address(wstETH));
        // set e-mode on aave-v3 for increased borrowing capacity to 90% of collateral
        IPool(C.AAVE_POOL).setUserEMode(C.AAVE_EMODE_ID);

        slippageTolerance = _params.slippageTolerance;

        _addProtocols(_params.protocolParams);
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
    function harvest(Protocol protocol) external onlyKeeper {
        // reinvest
        _rebalancePosition(protocol);

        // store the old total
        uint256 oldTotalInvested = totalInvested;
        uint256 assets = totalAssets();

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

    // /// @notice increase/decrease the target ltv used on borrows
    // /// @param newTargetLtv the new target ltv
    // /// @dev the new target ltv must be less than the max ltv allowed on aave
    // function applyNewTargetLtv(uint256 newTargetLtv, Protocol protocol) public onlyKeeper {
    //     if (newTargetLtv >= getMaxLtv()) revert InvalidTargetLtv();

    //     targetLtv = newTargetLtv;

    //     _rebalancePosition(protocol);

    //     emit NewTargetLtvApplied(msg.sender, newTargetLtv);
    // }

    /// @notice withdraw funds from the strategy into the vault
    /// @param amount : amount of assets to withdraw into the vault
    function withdrawToVault(uint256 amount, Protocol protocol) external onlyKeeper {
        _withdrawToVault(amount);
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

    /// @notice returns the total wstETH supplied as collateral (in ETH)
    function totalCollateral() public view returns (uint256) {
        return _wstEthToEth(IAToken(C.AAVE_AWSTETH_TOKEN).balanceOf(address(this)));
    }

    /// @notice returns the total ETH borrowed
    function totalDebt() public view returns (uint256) {
        return ERC20(C.AAVAAVE_VAR_DEBT_WETH_TOKEN).balanceOf(address(this));
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

    /// @notice returns the max loan to value(ltv) ratio for borrowing eth on Aavev3 with wsteth as collateral for the flashloan (1e18 = 100%)
    function getMaxLtv() public view returns (uint256) {
        return uint256(IPool(C.AAVE_POOL).getEModeCategoryData(C.AAVE_EMODE_ID).ltv) * 1e14;
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

    /// @dev called after the flashLoan on _rebalancePosition
    function receiveFlashLoan(address[] memory, uint256[] memory amounts, uint256[] memory, bytes memory userData)
        external
    {
        if (msg.sender != address(balancerVault)) {
            revert InvalidFlashLoanCaller();
        }

        // the amount flashloaned
        uint256 flashLoanAmount = amounts[0];

        // decode user data
        (FlashLoanParams memory params) = abi.decode(userData, (FlashLoanParams));

        params.amount += flashLoanAmount;

        // if flashloan received as part of a deposit
        if (params.isDeposit) {
            // unwrap eth
            weth.withdraw(params.amount);

            // stake to lido / eth => stETH
            stEth.submit{value: params.amount}(address(0x00));

            // wrap stETH
            wstETH.wrap(stEth.balanceOf(address(this)));

            _supplyBorrow(params.amounts, params.flashLoanAmounts);
        }
        // if flashloan received as part of a withdrawal
        else {
            // _repayWithdraw(flashLoanAmount, params.amount, params.protocol);

            // unwrap wstETH
            uint256 stEthAmount = wstETH.unwrap(wstETH.balanceOf(address(this)));

            // stETH to eth
            curvePool.exchange(1, 0, stEthAmount, _stEthToEth(stEthAmount).mulWadDown(slippageTolerance));

            // wrap eth
            weth.deposit{value: address(this).balance}();
        }

        // payback flashloan
        asset.safeTransfer(address(balancerVault), flashLoanAmount);
    }

    // need to be able to receive eth
    receive() external payable {}

    //////////////////// INTERNAL METHODS //////////////////////////

    /// @notice returns the debt on a particular protocol
    function getDebt(Protocol protocol) public view returns (uint256 debt) {
        if (protocol == Protocol.AAVE_V3) {
            // todo
        } else if (protocol == Protocol.EULER) {
            // todo
        }
    }

    /// @notice returns the collateral supplied on a particular protocol
    function getCollateral(Protocol protocol) public view returns (uint256 collateral) {
        if (protocol == Protocol.AAVE_V3) {
            // todo
        } else if (protocol == Protocol.EULER) {
            // todo
        }
    }

    function _calcFlashLoanAmount(Protocol protocol, uint256 totalAmount)
        internal
        view
        returns (uint256 flashLoanAmount, uint256 target, uint256 debt, uint256 supplyAmount)
    {
        ProtocolParams memory params = protocolParams[protocol];

        uint256 amount = totalAmount.mulWadDown(params.allocationPercent);
        debt = getDebt(protocol);
        uint256 collateral = getCollateral(protocol);

        target = uint256(params.targetLtv).mulWadDown(amount + collateral);

        // calculate the flashloan amount needed
        flashLoanAmount = (target > debt ? target - debt : debt - target).divWadDown(C.ONE - params.targetLtv);
    }

    function _rebalancePosition(Protocol protocol) internal {
        // storage loads
        uint256 totalAmount = asset.balanceOf(address(this));

        (uint256 aaveFlashLoanAmount, uint256 aaveV3Target, uint256 aaveV3Debt, uint256 aaveV3SupplyAmount) =
            _calcFlashLoanAmount(Protocol.AAVE_V3, totalAmount);
        (uint256 eulerFlashLoanAmount, uint256 eulerTarget, uint256 eulerDebt, uint256 eulerSupplyAmount) =
            _calcFlashLoanAmount(Protocol.EULER, totalAmount);

        uint256 target = aaveV3Target + eulerTarget;
        uint256 debt = aaveV3Debt + eulerDebt;

        uint256 flashLoanAmount = aaveFlashLoanAmount + eulerFlashLoanAmount;

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;

        uint256[] memory supplyAmounts = new uint[](2);
        supplyAmounts[0] = aaveV3SupplyAmount;
        supplyAmounts[1] = eulerSupplyAmount;

        uint256[] memory flashLoanAmounts = new uint[](2);
        flashLoanAmounts[0] = aaveFlashLoanAmount;
        flashLoanAmounts[1] = eulerFlashLoanAmount;

        // needed otherwise counted as profit during harvest
        totalInvested += totalAmount;

        // when deleveraging, withdraw extra to cover slippage
        // if (!isDeposit) totalAmount += flashLoanAmount.mulWadDown(C.ONE - slippageTolerance);

        FlashLoanParams memory params = FlashLoanParams(target > debt, totalAmount, supplyAmounts, flashLoanAmounts);

        // take flashloan
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(params));
    }

    function _withdrawToVault(uint256 amount) internal {
        uint256 debt = totalDebt();
        uint256 collateral = totalCollateral();

        uint256 flashLoanAmount = amount.mulDivDown(debt, collateral - debt);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;

        // needed otherwise counted as loss during harvest
        totalInvested -= amount;

        // FlashLoanParams memory params = FlashLoanParams(false, amount);

        // take flashloan
        // balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(params));
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

    function _ethToWstEth(uint256 ethAmount) internal view returns (uint256 wstEthAmount) {
        if (ethAmount > 0) {
            (, int256 price,,,) = stEThToEthPriceFeed.latestRoundData();

            // eth to stEth
            uint256 stEthAmount = ethAmount.divWadDown(uint256(price));

            // stEth to wstEth
            wstEthAmount = wstETH.getWstETHByStETH(stEthAmount);
        }
    }

    function _supplyBorrow(uint256[] memory amounts, uint256[] memory flashLoanAmounts) internal {
        // aave-v3
        IPool(C.AAVE_POOL).supply(address(wstETH), _ethToWstEth(amounts[0]), address(this), 0);
        IPool(C.AAVE_POOL).borrow(address(weth), flashLoanAmounts[0], C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));

        // Euler
        IEulerEToken(C.EULER_ETOKEN_WSTETH).deposit(0, _ethToWstEth(amounts[1]));
        IEulerDToken(C.EULER_DTOKEN_WETH).borrow(0, flashLoanAmounts[1]);
    }

    function _repayWithdraw(uint256[] memory amounts, uint256[] memory flashLoanAmounts) internal {
        // bool withdrawAll = flashLoanAmount >= totalDebt();

        // aave v3
        IPool(C.AAVE_POOL).repay(address(weth), flashLoanAmounts[0], C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
        IPool(C.AAVE_POOL).withdraw(address(wstETH), _ethToWstEth(amounts[0] + flashLoanAmounts[0]), address(this));

        // euler
        IEulerDToken(C.EULER_DTOKEN_WETH).repay(0, flashLoanAmounts[1]);
        IEulerEToken(C.EULER_ETOKEN_WSTETH).withdraw(0, _ethToWstEth(amounts[1] + flashLoanAmounts[1]));
    }

    function beforeWithdraw(uint256 assets, uint256) internal override {
        uint256 float = asset.balanceOf(address(this));
        if (assets <= float) {
            return;
        }

        uint256 missing = (assets - float);

        // todo: protocol hardcoded for now, change it later when withdraw method is turned async
        _withdrawToVault(missing);
    }
}
