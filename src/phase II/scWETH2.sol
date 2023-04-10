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
        EULER,
        COMPOUND
    }

    struct FlashLoanParams {
        bool isDeposit;
        uint256 amount;
        Protocol protocol; // the protocol for supply/borrow or withdraw/repay
    }

    struct ConstructorParams {
        address admin;
        address keeper;
        uint256 targetLtv;
        uint256 slippageTolerance;
        IPool aavePool;
        IAToken aaveAwstEth;
        ERC20 aaveVarDWeth;
        ICurvePool curveEthStEthPool;
        ILido stEth;
        IwstETH wstEth;
        WETH weth;
        AggregatorV3Interface stEthToEthPriceFeed;
        IVault balancerVault;
    }

    IPool public immutable aavePool;
    // aToken is a rebasing token and pegged 1:1 to the underlying
    IAToken public immutable aToken;
    ERC20 public immutable variableDebtToken;

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

    // the target ltv ratio at which we actually borrow (<= maxLtv)
    uint256 public targetLtv;

    // slippage for curve swaps
    uint256 public slippageTolerance;

    constructor(ConstructorParams memory _params)
        sc4626(_params.admin, _params.keeper, _params.weth, "Sandclock WETH Vault", "scWETH")
    {
        if (_params.slippageTolerance > C.ONE) revert InvalidSlippageTolerance();

        aavePool = _params.aavePool;
        aToken = _params.aaveAwstEth;
        variableDebtToken = _params.aaveVarDWeth;
        curvePool = _params.curveEthStEthPool;
        stEth = _params.stEth;
        wstETH = _params.wstEth;
        weth = _params.weth;
        stEThToEthPriceFeed = _params.stEthToEthPriceFeed;
        balancerVault = _params.balancerVault;

        ERC20(address(stEth)).safeApprove(address(wstETH), type(uint256).max);
        ERC20(address(stEth)).safeApprove(address(curvePool), type(uint256).max);
        ERC20(address(wstETH)).safeApprove(address(aavePool), type(uint256).max);
        ERC20(address(weth)).safeApprove(address(aavePool), type(uint256).max);

        // set e-mode on aave-v3 for increased borrowing capacity to 90% of collateral
        aavePool.setUserEMode(C.AAVE_EMODE_ID);

        if (_params.targetLtv >= getMaxLtv()) revert InvalidTargetLtv();

        targetLtv = _params.targetLtv;
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

    /// @notice increase/decrease the target ltv used on borrows
    /// @param newTargetLtv the new target ltv
    /// @dev the new target ltv must be less than the max ltv allowed on aave
    function applyNewTargetLtv(uint256 newTargetLtv, Protocol protocol) public onlyKeeper {
        if (newTargetLtv >= getMaxLtv()) revert InvalidTargetLtv();

        targetLtv = newTargetLtv;

        _rebalancePosition(protocol);

        emit NewTargetLtvApplied(msg.sender, newTargetLtv);
    }

    /// @notice withdraw funds from the strategy into the vault
    /// @param amount : amount of assets to withdraw into the vault
    function withdrawToVault(uint256 amount, Protocol protocol) external onlyKeeper {
        _withdrawToVault(amount, protocol);
    }

    //////////////////// VIEW METHODS //////////////////////////

    /// @notice returns the total assets (WETH) held by the strategy
    function totalAssets() public view override returns (uint256 assets) {
        // value of the supplied collateral in eth terms using chainlink oracle
        assets = getCollateral();

        // subtract the debt
        assets -= getDebt();

        // add float
        assets += asset.balanceOf(address(this));
    }

    /// @notice returns the total wstETH supplied as collateral (in ETH)
    function getCollateral() public view returns (uint256) {
        return _wstEthToEth(aToken.balanceOf(address(this)));
    }

    /// @notice returns the total ETH borrowed
    function getDebt() public view returns (uint256) {
        return variableDebtToken.balanceOf(address(this));
    }

    /// @notice returns the net leverage that the strategy is using right now (1e18 = 100%)
    function getLeverage() public view returns (uint256) {
        uint256 coll = getCollateral();
        return coll > 0 ? coll.divWadUp(coll - getDebt()) : 0;
    }

    /// @notice returns the net LTV at which we have borrowed till now (1e18 = 100%)
    function getLtv() public view returns (uint256 ltv) {
        uint256 collateral = getCollateral();
        if (collateral > 0) {
            // getDebt / totalSupplied
            ltv = getDebt().divWadUp(collateral);
        }
    }

    /// @notice returns the max loan to value(ltv) ratio for borrowing eth on Aavev3 with wsteth as collateral for the flashloan (1e18 = 100%)
    function getMaxLtv() public view returns (uint256) {
        return uint256(aavePool.getEModeCategoryData(C.AAVE_EMODE_ID).ltv) * 1e14;
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

            _supplyBorrow(flashLoanAmount, params.protocol);
        }
        // if flashloan received as part of a withdrawal
        else {
            _repayWithdraw(flashLoanAmount, params.amount, params.protocol);

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

    function _rebalancePosition(Protocol protocol) internal {
        // storage loads
        uint256 amount = asset.balanceOf(address(this));
        uint256 ltv = targetLtv;
        uint256 debt = getDebt();
        uint256 collateral = getCollateral();

        uint256 target = ltv.mulWadDown(amount + collateral);

        // whether we should deposit or withdraw
        bool isDeposit = target > debt;

        // calculate the flashloan amount needed
        uint256 flashLoanAmount = (isDeposit ? target - debt : debt - target).divWadDown(C.ONE - ltv);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;

        // needed otherwise counted as profit during harvest
        totalInvested += amount;

        // when deleveraging, withdraw extra to cover slippage
        if (!isDeposit) amount += flashLoanAmount.mulWadDown(C.ONE - slippageTolerance);

        FlashLoanParams memory params = FlashLoanParams(isDeposit, amount, protocol);

        // take flashloan
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(params));
    }

    function _withdrawToVault(uint256 amount, Protocol protocol) internal {
        uint256 debt = getDebt();
        uint256 collateral = getCollateral();

        uint256 flashLoanAmount = amount.mulDivDown(debt, collateral - debt);

        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashLoanAmount;

        // needed otherwise counted as loss during harvest
        totalInvested -= amount;

        FlashLoanParams memory params = FlashLoanParams(false, amount, protocol);

        // take flashloan
        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(params));
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

    function _supplyBorrow(uint256 flashLoanAmount, Protocol protocol) internal {
        if (protocol == Protocol.AAVE_V3) {
            //add wstETH liquidity on aave-v3
            aavePool.supply(address(wstETH), wstETH.balanceOf(address(this)), address(this), 0);
            //borrow enough weth from aave-v3 to payback flashloan
            aavePool.borrow(address(weth), flashLoanAmount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
        } else if (protocol == Protocol.EULER) {
            // todo
        } else {
            // todo
        }
    }

    function _repayWithdraw(uint256 flashLoanAmount, uint256 amount, Protocol protocol) internal {
        if (protocol == Protocol.AAVE_V3) {
            // repay debt + withdraw collateral
            if (flashLoanAmount >= getDebt()) {
                aavePool.repay(address(weth), type(uint256).max, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
                aavePool.withdraw(address(wstETH), type(uint256).max, address(this));
            } else {
                aavePool.repay(address(weth), flashLoanAmount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
                aavePool.withdraw(address(wstETH), _ethToWstEth(amount), address(this));
            }
        } else if (protocol == Protocol.EULER) {
            // todo
        } else {
            // todo
        }
    }

    function beforeWithdraw(uint256 assets, uint256) internal override {
        uint256 float = asset.balanceOf(address(this));
        if (assets <= float) {
            return;
        }

        uint256 missing = (assets - float);

        // todo: protocol hardcoded for now, change it later when withdraw method is turned async
        _withdrawToVault(missing, Protocol.AAVE_V3);
    }
}
