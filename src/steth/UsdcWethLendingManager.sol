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
import {ILendingPool} from "../interfaces/aave-v2/ILendingPool.sol";
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
        AAVE_V2,
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

    mapping(Protocol => ProtocolActions) protocolToActions;

    ERC20 public immutable usdc;
    WETH public immutable weth;

    ILendingPool public immutable aaveV2Pool;
    ERC20 public immutable aaveV2AUsdc;
    ERC20 public immutable aaveV2VarDWeth;

    IPool public immutable aaveV3Pool;
    IPoolDataProvider public immutable aaveV3PoolDataProvider;
    IAToken public immutable aaveV3AUsdc;
    ERC20 public immutable aaveV3VarDWeth;

    address public immutable eulerProtocol;
    IEulerMarkets public immutable eulerMarkets;
    IEulerEToken public immutable eulerEUsdc;
    IEulerDToken public immutable eulerDWeth;
    ERC20 public immutable eulerRewardsToken;

    struct AaveV3 {
        IPool pool;
        IPoolDataProvider poolDataProvider;
        IAToken aUsdc;
        ERC20 varDWeth;
    }

    struct Euler {
        address protocol;
        IEulerMarkets markets;
        IEulerEToken eUsdc;
        IEulerDToken dWeth;
        ERC20 rewardsToken;
    }

    struct AaveV2 {
        ILendingPool pool;
        ERC20 aUsdc;
        ERC20 varDWeth;
    }

    constructor(ERC20 _usdc, WETH _weth, AaveV3 memory _aaveV3, AaveV2 memory _aaveV2, Euler memory _euler) {
        usdc = _usdc;
        weth = _weth;

        aaveV3Pool = _aaveV3.pool;
        aaveV3PoolDataProvider = _aaveV3.poolDataProvider;
        aaveV3AUsdc = _aaveV3.aUsdc;
        aaveV3VarDWeth = _aaveV3.varDWeth;

        eulerProtocol = _euler.protocol;
        eulerMarkets = _euler.markets;
        eulerEUsdc = _euler.eUsdc;
        eulerDWeth = _euler.dWeth;
        eulerRewardsToken = _euler.rewardsToken;

        aaveV2Pool = _aaveV2.pool;
        aaveV2AUsdc = _aaveV2.aUsdc;
        aaveV2VarDWeth = _aaveV2.varDWeth;

        usdc.safeApprove(address(aaveV3Pool), type(uint256).max);
        weth.safeApprove(address(aaveV3Pool), type(uint256).max);

        usdc.safeApprove(eulerProtocol, type(uint256).max);
        weth.safeApprove(eulerProtocol, type(uint256).max);
        eulerMarkets.enterMarket(0, address(usdc));

        usdc.safeApprove(address(aaveV2Pool), type(uint256).max);
        weth.safeApprove(address(aaveV2Pool), type(uint256).max);

        protocolToActions[Protocol.AAVE_V2] = ProtocolActions(
            supplyUsdcOnAaveV2,
            borrowWethOnAaveV2,
            repayDebtOnAaveV2,
            withdrawUsdcOnAaveV2,
            getCollateralOnAaveV2,
            getDebtOnAaveV2,
            getMaxLtvOnAaveV2
        );
        protocolToActions[Protocol.AAVE_V3] = ProtocolActions(
            supplyUsdcOnAaveV3,
            borrowWethOnAaveV3,
            repayDebtOnAaveV3,
            withdrawUsdcOnAaveV3,
            getCollateralOnAaveV3,
            getDebtOnAaveV3,
            getMaxLtvOnAaveV3
        );
        protocolToActions[Protocol.EULER] = ProtocolActions(
            supplyUsdcOnEuler,
            borrowWethOnEuler,
            repayDebtOnEuler,
            withdrawUsdcOnEuler,
            getCollateralOnEuler,
            getDebtOnEuler,
            getMaxLtvOnEuler
        );
    }

    function getMaxLtv(Protocol _protocolId) public view returns (uint256) {
        return protocolToActions[_protocolId].getMaxLtv();
    }

    /*//////////////////////////////////////////////////////////////
                            AAVE_V2 API
    //////////////////////////////////////////////////////////////*/

    function supplyUsdcOnAaveV2(uint256 _amount) internal {
        aaveV2Pool.deposit(address(usdc), _amount, address(this), 0);
    }

    function borrowWethOnAaveV2(uint256 _amount) internal {
        aaveV2Pool.borrow(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
    }

    function repayDebtOnAaveV2(uint256 _amount) internal {
        aaveV2Pool.repay(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
    }

    function withdrawUsdcOnAaveV2(uint256 _amount) internal {
        aaveV2Pool.withdraw(address(usdc), _amount, address(this));
    }

    function getCollateralOnAaveV2() internal view returns (uint256) {
        return aaveV2AUsdc.balanceOf(address(this));
    }

    function getDebtOnAaveV2() internal view returns (uint256) {
        return aaveV2VarDWeth.balanceOf(address(this));
    }

    function getMaxLtvOnAaveV2() internal view returns (uint256) {
        // TODO: fix this
        (, uint256 ltv,,,,,,,,) = aaveV3PoolDataProvider.getReserveConfigurationData(address(usdc));

        // ltv is returned as a percentage with 2 decimals (e.g. 80% = 8000) so we need to multiply by 1e14
        // return ltv * 1e14;
        return 1e18;
    }

    /*//////////////////////////////////////////////////////////////
                            AAVE_V3 API
    //////////////////////////////////////////////////////////////*/

    function supplyUsdcOnAaveV3(uint256 _amount) internal {
        aaveV3Pool.supply(address(usdc), _amount, address(this), 0);
    }

    function borrowWethOnAaveV3(uint256 _amount) internal {
        aaveV3Pool.borrow(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
    }

    function repayDebtOnAaveV3(uint256 _amount) internal {
        aaveV3Pool.repay(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
    }

    function withdrawUsdcOnAaveV3(uint256 _amount) internal {
        aaveV3Pool.withdraw(address(usdc), _amount, address(this));
    }

    function getCollateralOnAaveV3() internal view returns (uint256) {
        return aaveV3AUsdc.balanceOf(address(this));
    }

    function getDebtOnAaveV3() internal view returns (uint256) {
        return aaveV3VarDWeth.balanceOf(address(this));
    }

    function getMaxLtvOnAaveV3() internal view returns (uint256) {
        (, uint256 ltv,,,,,,,,) = aaveV3PoolDataProvider.getReserveConfigurationData(address(usdc));

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

    function getCollateralOnEuler() internal view returns (uint256) {
        return eulerEUsdc.balanceOfUnderlying(address(this));
    }

    function getDebtOnEuler() internal view returns (uint256) {
        return eulerDWeth.balanceOf(address(this));
    }

    function getMaxLtvOnEuler() internal view returns (uint256) {
        uint256 collateralFactor = eulerMarkets.underlyingToAssetConfig(address(usdc)).collateralFactor;
        uint256 borrowFactor = eulerMarkets.underlyingToAssetConfig(address(weth)).borrowFactor;

        uint256 scaledCollateralFactor = collateralFactor.divWadDown(C.EULER_CONFIG_FACTOR_SCALE);
        uint256 scaledBorrowFactor = borrowFactor.divWadDown(C.EULER_CONFIG_FACTOR_SCALE);

        return scaledCollateralFactor.mulWadDown(scaledBorrowFactor);
    }
}
