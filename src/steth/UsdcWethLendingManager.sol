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

abstract contract UsdcWethLendingManager {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    using FixedPointMathLib for uint256;

    enum Protocol {
        AAVE_V3,
        EULER
    }

    struct ProtocolActions {
        function(uint256) supply;
        function(uint256) borrow;
        function(uint256) repay;
        function(uint256) withdraw;
        function() view returns(uint256) getCollateral;
        function() view returns(uint256) getDebt;
        function() view returns(uint256) getMaxLtv;
    }

    mapping(Protocol => ProtocolActions) lendingProtocols;

    ERC20 public immutable usdc;
    WETH public immutable weth;

    IPool public immutable aavePool;
    IPoolDataProvider public immutable aavePoolDataProvider;
    IAToken public immutable aaveAUsdc;
    ERC20 public immutable aaveVarDWeth;

    address public immutable eulerProtocol;
    IEulerMarkets public immutable eulerMarkets;
    IEulerEToken public immutable eulerEUsdc;
    IEulerDToken public immutable eulerDWeth;
    ERC20 public immutable eulerRewardsToken;

    constructor(
        ERC20 _usdc,
        WETH _weth,
        IPool _aavePool,
        IPoolDataProvider _aavePoolDataProvider,
        IAToken _aaveAUsdc,
        ERC20 _aaveVarDWeth,
        address _eulerProtocol,
        IEulerMarkets _eulerMarkets,
        IEulerEToken _eulerEUsdc,
        IEulerDToken _eulerDWeth,
        ERC20 _eulerRewardsToken
    ) {
        usdc = _usdc;
        weth = _weth;

        aavePool = _aavePool;
        aavePoolDataProvider = _aavePoolDataProvider;
        aaveAUsdc = _aaveAUsdc;
        aaveVarDWeth = _aaveVarDWeth;

        eulerProtocol = _eulerProtocol;
        eulerMarkets = _eulerMarkets;
        eulerEUsdc = _eulerEUsdc;
        eulerDWeth = _eulerDWeth;
        eulerRewardsToken = _eulerRewardsToken;

        usdc.safeApprove(address(aavePool), type(uint256).max);
        weth.safeApprove(address(aavePool), type(uint256).max);

        usdc.safeApprove(eulerProtocol, type(uint256).max);
        weth.safeApprove(eulerProtocol, type(uint256).max);
        eulerMarkets.enterMarket(0, address(usdc));

        lendingProtocols[Protocol.AAVE_V3] = ProtocolActions(
            supplyUsdcOnAave,
            borrowWethOnAave,
            repayDebtOnAave,
            withdrawUsdcOnAave,
            getCollateralOnAave,
            getDebtOnAave,
            getMaxLtvOnAave
        );
        lendingProtocols[Protocol.EULER] = ProtocolActions(
            supplyUsdcOnEuler,
            borrowWethOnEuler,
            repayDebtOnEuler,
            withdrawUsdcOnEuler,
            getCollateralOnEuler,
            getDebtOnEuler,
            getMaxLtvOnEuler
        );
    }

    /*//////////////////////////////////////////////////////////////
                            AAVE API
    //////////////////////////////////////////////////////////////*/

    function supplyUsdcOnAave(uint256 _amount) internal {
        aavePool.supply(address(usdc), _amount, address(this), 0);
    }

    function borrowWethOnAave(uint256 _amount) internal {
        aavePool.borrow(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
    }

    function repayDebtOnAave(uint256 _amount) internal {
        aavePool.repay(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
    }

    function withdrawUsdcOnAave(uint256 _amount) internal {
        aavePool.withdraw(address(usdc), _amount, address(this));
    }

    function getCollateralOnAave() public view returns (uint256) {
        return aaveAUsdc.balanceOf(address(this));
    }

    function getDebtOnAave() public view returns (uint256) {
        return aaveVarDWeth.balanceOf(address(this));
    }

    function getMaxLtvOnAave() public view returns (uint256) {
        (, uint256 ltv,,,,,,,,) = aavePoolDataProvider.getReserveConfigurationData(address(usdc));

        // ltv is returned as a percentage with 2 decimals (e.g. 80% = 8000) so we need to multiply by 1e14
        return ltv * 1e14;
    }

    /*//////////////////////////////////////////////////////////////
                            EULER API
    //////////////////////////////////////////////////////////////*/

    function supplyUsdcOnEuler(uint256 _amount) internal {
        eulerEUsdc.deposit(0, _amount);
    }

    function borrowWethOnEuler(uint256 _amount) internal {
        eulerDWeth.borrow(0, _amount);
    }

    function repayDebtOnEuler(uint256 _amount) internal {
        eulerDWeth.repay(0, _amount);
    }

    function withdrawUsdcOnEuler(uint256 _amount) internal {
        eulerEUsdc.withdraw(0, _amount);
    }

    function getCollateralOnEuler() public view returns (uint256) {
        return eulerEUsdc.balanceOfUnderlying(address(this));
    }

    function getDebtOnEuler() public view returns (uint256) {
        return eulerDWeth.balanceOf(address(this));
    }

    function getMaxLtvOnEuler() public view returns (uint256) {
        uint256 collateralFactor = eulerMarkets.underlyingToAssetConfig(address(usdc)).collateralFactor;
        uint256 borrowFactor = eulerMarkets.underlyingToAssetConfig(address(weth)).borrowFactor;

        uint256 scaledCollateralFactor = collateralFactor.divWadDown(C.EULER_CONFIG_FACTOR_SCALE);
        uint256 scaledBorrowFactor = borrowFactor.divWadDown(C.EULER_CONFIG_FACTOR_SCALE);

        return scaledCollateralFactor.mulWadDown(scaledBorrowFactor);
    }
}
