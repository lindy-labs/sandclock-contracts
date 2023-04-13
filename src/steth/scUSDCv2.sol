// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {
    InvalidTargetLtv,
    InvalidSlippageTolerance,
    InvalidFlashLoanCaller,
    VaultNotUnderwater
} from "../errors/scErrors.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";
import {IEulerMarkets, IEulerEToken, IEulerDToken} from "lib/euler-interfaces/contracts/IEuler.sol";

import {Constants as C} from "../lib/Constants.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {ISwapRouter} from "../interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";
import {sc4626} from "../sc4626.sol";

/**
 * @title Sandclock USDC Vault
 * @notice A vault that allows users to earn interest on their USDC deposits from leveraged WETH staking.
 * @dev This vault uses Sandclock's leveraged WETH staking vault - scWETH.
 */
contract scUSDCv2 is sc4626, IFlashLoanRecipient {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    using FixedPointMathLib for uint256;

    enum LendingMarkets {
        AAVE_V3,
        EULER
    }

    struct LendingMarket {
        function(uint256) supplyFunc;
        function(uint256) borrowFunc;
        function(uint256) repayFunc;
        function(uint256) withdrawFunc;
        function() view returns(uint256) getCollateralFunc;
        function() view returns(uint256) getDebtFunc;
    }

    mapping(LendingMarkets => LendingMarket) lendingMarkets;

    event NewTargetLtvApplied(address indexed admin, uint256 newTargetLtv);
    event SlippageToleranceUpdated(address indexed admin, uint256 newSlippageTolerance);
    event EmergencyExitExecuted(
        address indexed admin, uint256 wethWithdrawn, uint256 debtRepaid, uint256 collateralReleased
    );
    event Rebalanced(
        uint256 targetLtv,
        uint256 initialDebt,
        uint256 finalDebt,
        uint256 initialCollateral,
        uint256 finalCollateral,
        uint256 initialUsdcBalance,
        uint256 finalUsdcBalance
    );

    WETH public immutable weth;

    // delta threshold for rebalancing in percentage
    uint256 constant DEBT_DELTA_THRESHOLD = 0.01e18;

    // main aave contract for interaction with the protocol
    IPool public immutable aavePool;
    // aave protocol data provider
    IPoolDataProvider public immutable aavePoolDataProvider;

    // aave "aEthUSDC" token
    IAToken public immutable aUsdc;
    // aave "variableDebtEthWETH" token
    ERC20 public immutable dWeth;

    // Uniswap V3 router
    ISwapRouter public immutable swapRouter;

    // Chainlink pricefeed (USDC -> WETH)
    AggregatorV3Interface public immutable usdcToEthPriceFeed;

    // Balancer vault for flashloans
    IVault public immutable balancerVault;

    // USDC / WETH target LTV
    uint256 public targetLtv = 0.65e18;
    // max slippage for swapping WETH -> USDC
    uint256 public slippageTolerance = 0.99e18; // 1% default
    uint256 public constant rebalanceMinimum = 10e6; // 10 USDC

    // leveraged (w)eth vault
    ERC4626 public immutable scWETH;

    // EULER lending market
    address public constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;

    // euler rewards token EUL
    ERC20 public eul = ERC20(0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b);

    // The Euler market contract
    IEulerMarkets public constant markets = IEulerMarkets(0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3);

    // Euler supply token for USDC (eUSDC)
    IEulerEToken public constant eulUsdc = IEulerEToken(0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716);

    // Euler debt token for WETH (dWETH)
    IEulerDToken public constant eulDWeth = IEulerDToken(0x62e28f054efc24b26A794F5C1249B6349454352C);

    struct ConstructorParams {
        address admin;
        address keeper;
        ERC4626 scWETH;
        ERC20 usdc;
        WETH weth;
        IPool aavePool;
        IPoolDataProvider aavePoolDataProvider;
        IAToken aaveAUsdc;
        ERC20 aaveVarDWeth;
        ISwapRouter uniswapSwapRouter;
        AggregatorV3Interface chainlinkUsdcToEthPriceFeed;
        IVault balancerVault;
    }

    constructor(ConstructorParams memory _params)
        sc4626(_params.admin, _params.keeper, _params.usdc, "Sandclock USDC Vault", "scUSDC")
    {
        scWETH = _params.scWETH;
        weth = _params.weth;
        aavePool = _params.aavePool;
        aavePoolDataProvider = _params.aavePoolDataProvider;
        aUsdc = _params.aaveAUsdc;
        dWeth = _params.aaveVarDWeth;
        swapRouter = _params.uniswapSwapRouter;
        usdcToEthPriceFeed = _params.chainlinkUsdcToEthPriceFeed;
        balancerVault = _params.balancerVault;

        asset.safeApprove(address(aavePool), type(uint256).max);

        weth.safeApprove(address(aavePool), type(uint256).max);
        weth.safeApprove(address(swapRouter), type(uint256).max);
        weth.safeApprove(address(_params.scWETH), type(uint256).max);

        asset.safeApprove(EULER, type(uint256).max);
        weth.safeApprove(EULER, type(uint256).max);
        markets.enterMarket(0, address(asset));

        lendingMarkets[LendingMarkets.AAVE_V3] = LendingMarket(
            supplyUsdcOnAave, borrowWethOnAave, repayDebtOnAave, withdrawUsdcOnAave, getCollateralOnAave, getDebtOnAave
        );
        lendingMarkets[LendingMarkets.EULER] = LendingMarket(
            supplyUsdcOnEuler,
            borrowWethOnEuler,
            repayDebtOnEuler,
            withdrawUsdcOnEuler,
            getCollateralOnEuler,
            getDebtOnEuler
        );
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC API
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set the slippage tolerance for swapping WETH to USDC on Uniswap.
     * @param _newSlippageTolerance The new slippage tolerance value.
     */
    function setSlippageTolerance(uint256 _newSlippageTolerance) external onlyAdmin {
        if (_newSlippageTolerance > C.ONE) revert InvalidSlippageTolerance();

        slippageTolerance = _newSlippageTolerance;

        emit SlippageToleranceUpdated(msg.sender, _newSlippageTolerance);
    }

    struct ReallocationParams {
        LendingMarkets marketId;
        bool isDownsize;
        uint256 collateralAmount;
        uint256 debtAmount;
    }

    /**
     * @notice Allocate capital between lending markets.
     * @param _params The allocation parameters. Markets where positions are downsized must be listed first.
     */
    function reallocateCapital(ReallocationParams[] calldata _params, uint256 _flashLoanAmount) public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = _flashLoanAmount;

        balancerVault.flashLoan(address(this), tokens, amounts, abi.encode(_params));
    }

    function receiveFlashLoan(address[] memory, uint256[] memory amounts, uint256[] memory, bytes memory userData)
        external
    {
        if (msg.sender != address(balancerVault)) {
            revert InvalidFlashLoanCaller();
        }

        uint256 flashLoanAmount = amounts[0];
        (ReallocationParams[] memory params) = abi.decode(userData, (ReallocationParams[]));

        for (uint8 i = 0; i < params.length; i++) {
            if (params[i].isDownsize) {
                lendingMarkets[params[i].marketId].repayFunc(params[i].debtAmount);
                lendingMarkets[params[i].marketId].withdrawFunc(params[i].collateralAmount);
            } else {
                lendingMarkets[params[i].marketId].supplyFunc(params[i].collateralAmount);
                lendingMarkets[params[i].marketId].borrowFunc(params[i].debtAmount);
            }
        }

        weth.safeTransfer(address(balancerVault), flashLoanAmount);
    }

    struct RebalanceParams {
        LendingMarkets marketId;
        uint256 addCollateralAmount;
        bool isBorrow;
        uint256 amount;
    }

    /**
     * @notice Rebalance the vault's positions.
     * @dev Called to increase or decrease the WETH debt to maintain the LTV (loan to value).
     */
    function rebalance(RebalanceParams[] calldata _params) public {
        for (uint8 i = 0; i < _params.length; i++) {
            // respect new deposits
            if (_params[i].addCollateralAmount != 0) {
                lendingMarkets[_params[i].marketId].supplyFunc(_params[i].addCollateralAmount);
            }

            // borrow and invest or disinvest and repay
            if (_params[i].isBorrow) {
                lendingMarkets[_params[i].marketId].borrowFunc(_params[i].amount);
                scWETH.deposit(_params[i].amount, address(this));
            } else {
                uint256 withdrawn = _disinvest(_params[i].amount);
                lendingMarkets[_params[i].marketId].repayFunc(withdrawn);
            }
        }
    }

    // TODO: figure out how to separate protocol specific logic from the vault
    // AAVE

    function supplyUsdcOnAave(uint256 _amount) internal {
        aavePool.supply(address(asset), _amount, address(this), 0);
    }

    function borrowWethOnAave(uint256 _amount) internal {
        aavePool.borrow(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
    }

    function repayDebtOnAave(uint256 _amount) internal {
        aavePool.repay(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
    }

    function withdrawUsdcOnAave(uint256 _amount) internal {
        aavePool.withdraw(address(asset), _amount, address(this));
    }

    function getCollateralOnAave() public view returns (uint256) {
        return aUsdc.balanceOf(address(this));
    }

    function getDebtOnAave() public view returns (uint256) {
        return dWeth.balanceOf(address(this));
    }

    // EULER

    function supplyUsdcOnEuler(uint256 _amount) internal {
        eulUsdc.deposit(0, _amount);
    }

    function borrowWethOnEuler(uint256 _amount) internal {
        eulDWeth.borrow(0, _amount);
    }

    function repayDebtOnEuler(uint256 _amount) internal {
        eulDWeth.repay(0, _amount);
    }

    function withdrawUsdcOnEuler(uint256 _amount) internal {
        eulUsdc.withdraw(0, _amount);
    }

    function getCollateralOnEuler() public view returns (uint256) {
        return eulUsdc.balanceOfUnderlying(address(this));
    }

    function getDebtOnEuler() public view returns (uint256) {
        return eulDWeth.balanceOf(address(this));
    }

    function totalAssets() public view override returns (uint256) {
        return _calculateTotalAssets(getUsdcBalance(), getCollateral(), getInvested(), getDebt());
    }

    function getUsdcFromWeth(uint256 _wethAmount) public view returns (uint256) {
        (, int256 usdcPriceInWeth,,,) = usdcToEthPriceFeed.latestRoundData();

        return (_wethAmount / C.WETH_USDC_DECIMALS_DIFF).divWadDown(uint256(usdcPriceInWeth));
    }

    function getWethFromUsdc(uint256 _usdcAmount) public view returns (uint256) {
        (, int256 usdcPriceInWeth,,,) = usdcToEthPriceFeed.latestRoundData();

        return (_usdcAmount * C.WETH_USDC_DECIMALS_DIFF).mulWadDown(uint256(usdcPriceInWeth));
    }

    /**
     * @notice Returns the USDC balance of the vault.
     * @return The USDC balance.
     */
    function getUsdcBalance() public view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Returns the total USDC supplied as collateral to Aave.
     * @return The USDC collateral amount.
     */
    function getCollateral() public view returns (uint256) {
        // TODO: can be made protocol agnostic?
        return lendingMarkets[LendingMarkets.AAVE_V3].getCollateralFunc()
            + lendingMarkets[LendingMarkets.EULER].getCollateralFunc();
    }

    /**
     * @notice Returns the total WETH borrowed on Aave.
     * @return The borrowed WETH amount.
     */
    function getDebt() public view returns (uint256) {
        return lendingMarkets[LendingMarkets.AAVE_V3].getDebtFunc() + lendingMarkets[LendingMarkets.EULER].getDebtFunc();
    }

    /**
     * @notice Returns the amount of WETH invested in the leveraged WETH vault.
     * @return The WETH invested amount.
     */
    function getInvested() public view returns (uint256) {
        return scWETH.convertToAssets(scWETH.balanceOf(address(this)));
    }

    /**
     * @notice Returns the net LTV at which the vault has borrowed until now.
     * @return The current LTV (1e18 = 100%).
     */
    // TODO: make protocol specific
    function getLtv() public view returns (uint256) {
        uint256 debt = getDebt();

        if (debt == 0) return 0;

        uint256 debtPriceInUsdc = getUsdcFromWeth(debt);

        // totalDebt / totalSupplied
        return debtPriceInUsdc.divWadUp(getCollateral());
    }

    /**
     * @notice Returns the current max LTV for USDC / WETH loans on Aave.
     * @return The max LTV (1e18 = 100%).
     */
    // TODO: make protocol specific
    function getMaxLtv() public view returns (uint256) {
        (, uint256 ltv,,,,,,,,) = aavePoolDataProvider.getReserveConfigurationData(address(asset));

        // ltv is returned as a percentage with 2 decimals (e.g. 80% = 8000) so we need to multiply by 1e14
        return ltv * 1e14;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL API
    //////////////////////////////////////////////////////////////*/

    function beforeWithdraw(uint256 _assets, uint256) internal override {
        // TODO: find collateral allocation pct for each protocol and use that to calculate the amount to withdraw from each protocol
        uint256 initialBalance = getUsdcBalance();
        if (initialBalance >= _assets) return;

        uint256 collateral = getCollateral();
        uint256 debt = getDebt();
        uint256 invested = getInvested();
        uint256 total = _calculateTotalAssets(initialBalance, collateral, invested, debt);
        uint256 profit = _calculateWethProfit(invested, debt);
        uint256 floatRequired = total > _assets ? (total - _assets).mulWadUp(floatPercentage) : 0;
        uint256 usdcNeeded = _assets + floatRequired - initialBalance;

        // first try to sell profits to cover withdrawal amount
        if (profit != 0) {
            uint256 withdrawn = _disinvest(profit);
            uint256 usdcReceived = _swapWethForUsdc(withdrawn);

            if (initialBalance + usdcReceived >= _assets) return;

            usdcNeeded -= usdcReceived;
        }

        // if we still need more usdc, we need to repay debt and withdraw collateral
        _repayDebtAndReleaseCollateral(debt, collateral, invested, usdcNeeded);
    }

    function _repayDebtAndReleaseCollateral(uint256 _debt, uint256 _collateral, uint256 _invested, uint256 _usdcNeeded)
        internal
    {
        // handle rounding errors when withdrawing everything
        _usdcNeeded = _usdcNeeded > _collateral ? _collateral : _usdcNeeded;
        // to keep the same ltv, weth debt to repay has to be proportional to collateral withdrawn
        uint256 wethNeeded = _usdcNeeded.mulDivUp(_debt, _collateral);
        wethNeeded = wethNeeded > _invested ? _invested : wethNeeded;

        uint256 withdrawn = _disinvest(wethNeeded);
        // aavePool.repay(address(weth), withdrawn, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
        // aavePool.withdraw(address(asset), _usdcNeeded, address(this));
        // lendingMarkets[LendingMarkets.AAVE_V3].repayFunc(withdrawn);
        // lendingMarkets[LendingMarkets.AAVE_V3].withdrawFunc(_usdcNeeded);
        lendingMarkets[LendingMarkets.EULER].repayFunc(withdrawn);
        lendingMarkets[LendingMarkets.EULER].withdrawFunc(_usdcNeeded);
    }

    function _calculateTotalAssets(uint256 _float, uint256 _collateral, uint256 _invested, uint256 _debt)
        internal
        view
        returns (uint256 total)
    {
        total = _float + _collateral;

        uint256 profit = _calculateWethProfit(_invested, _debt);

        if (profit != 0) {
            // account for slippage when selling weth profits
            total += getUsdcFromWeth(profit).mulWadDown(slippageTolerance);
        } else {
            total -= getUsdcFromWeth(_debt - _invested);
        }
    }

    function _calculateWethProfit(uint256 _invested, uint256 _debt) internal pure returns (uint256) {
        return _invested > _debt ? _invested - _debt : 0;
    }

    function _disinvest(uint256 _wethAmount) internal returns (uint256 amountWithdrawn) {
        uint256 shares = scWETH.convertToShares(_wethAmount);

        amountWithdrawn = scWETH.redeem(shares, address(this), address(this));
    }

    function _swapWethForUsdc(uint256 _wethAmount) internal returns (uint256) {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(asset),
            fee: 500,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: _wethAmount,
            amountOutMinimum: getUsdcFromWeth(_wethAmount).mulWadDown(slippageTolerance),
            sqrtPriceLimitX96: 0
        });

        return swapRouter.exactInputSingle(params);
    }
}
