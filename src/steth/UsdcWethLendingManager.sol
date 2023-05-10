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
import {IProtocolDataProvider} from "../interfaces/aave-v2/IProtocolDataProvider.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {ISwapRouter} from "../interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";
import {sc4626} from "../sc4626.sol";

// TODO: celan up imports
contract UsdcWethLendingManager {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;
    using FixedPointMathLib for uint256;

    enum Protocol {
        AAVE_V2,
        AAVE_V3,
        EULER
    }

    ERC20 public immutable usdc;
    WETH public immutable weth;

    ILendingPool public immutable aaveV2Pool;
    IProtocolDataProvider public immutable aaveV2ProtocolDataProvider;
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
        IProtocolDataProvider protocolDataProvider;
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
        aaveV2ProtocolDataProvider = _aaveV2.protocolDataProvider;
        aaveV2AUsdc = _aaveV2.aUsdc;
        aaveV2VarDWeth = _aaveV2.varDWeth;
    }

    function supply(Protocol _protocolId, uint256 _amount) external {
        if (_protocolId == Protocol.AAVE_V2) {
            aaveV2Pool.deposit(address(usdc), _amount, address(this), 0);
        } else if (_protocolId == Protocol.AAVE_V3) {
            aaveV3Pool.supply(address(usdc), _amount, address(this), 0);
        } else {
            eulerEUsdc.deposit(0, _amount);
        }
    }

    function borrow(Protocol _protocolId, uint256 _amount) external {
        if (_protocolId == Protocol.AAVE_V2) {
            aaveV2Pool.borrow(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
        } else if (_protocolId == Protocol.AAVE_V3) {
            aaveV3Pool.borrow(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
        } else {
            eulerDWeth.borrow(0, _amount);
        }
    }

    function repay(Protocol _protocolId, uint256 _amount) external {
        if (_protocolId == Protocol.AAVE_V2) {
            aaveV2Pool.repay(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
        } else if (_protocolId == Protocol.AAVE_V3) {
            aaveV3Pool.repay(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
        } else {
            eulerDWeth.repay(0, _amount);
        }
    }

    function withdraw(Protocol _protocolId, uint256 _amount) external {
        if (_protocolId == Protocol.AAVE_V2) {
            aaveV2Pool.withdraw(address(usdc), _amount, address(this));
        } else if (_protocolId == Protocol.AAVE_V3) {
            aaveV3Pool.withdraw(address(usdc), _amount, address(this));
        } else {
            eulerEUsdc.withdraw(0, _amount);
        }
    }

    function getCollateral(Protocol _protocolId, address _account) public view returns (uint256 collateral) {
        if (_protocolId == Protocol.AAVE_V2) {
            collateral = aaveV2AUsdc.balanceOf(_account);
        } else if (_protocolId == Protocol.AAVE_V3) {
            collateral = aaveV3AUsdc.balanceOf(_account);
        } else {
            collateral = eulerEUsdc.balanceOfUnderlying(_account);
        }
    }

    function getTotalCollateral(address _account) public view returns (uint256) {
        return getCollateral(Protocol.AAVE_V2, _account) + getCollateral(Protocol.AAVE_V3, _account)
            + getCollateral(Protocol.EULER, _account);
    }

    function getDebt(Protocol _protocolId, address _account) public view returns (uint256 debt) {
        if (_protocolId == Protocol.AAVE_V2) {
            debt = aaveV2VarDWeth.balanceOf(_account);
        } else if (_protocolId == Protocol.AAVE_V3) {
            debt = aaveV3VarDWeth.balanceOf(_account);
        } else {
            debt = eulerDWeth.balanceOf(_account);
        }
    }

    function getTotalDebt(address _account) public view returns (uint256) {
        return getDebt(Protocol.AAVE_V2, _account) + getDebt(Protocol.AAVE_V3, _account)
            + getDebt(Protocol.EULER, _account);
    }

    function getMaxLtv(Protocol _protocolId) public view returns (uint256 maxLtv) {
        if (_protocolId == Protocol.AAVE_V2) {
            (, uint256 ltv,,,,,,,,) = aaveV2ProtocolDataProvider.getReserveConfigurationData(address(usdc));

            // ltv is returned as a percentage with 2 decimals (e.g. 80% = 8000) so we need to multiply by 1e14
            maxLtv = ltv * 1e14;
        } else if (_protocolId == Protocol.AAVE_V3) {
            (, uint256 ltv,,,,,,,,) = aaveV3PoolDataProvider.getReserveConfigurationData(address(usdc));

            // ltv is returned as a percentage with 2 decimals (e.g. 80% = 8000) so we need to multiply by 1e14
            maxLtv = ltv * 1e14;
        } else {
            uint256 collateralFactor = eulerMarkets.underlyingToAssetConfig(address(usdc)).collateralFactor;
            uint256 borrowFactor = eulerMarkets.underlyingToAssetConfig(address(weth)).borrowFactor;

            uint256 scaledCollateralFactor = collateralFactor.divWadDown(C.EULER_CONFIG_FACTOR_SCALE);
            uint256 scaledBorrowFactor = borrowFactor.divWadDown(C.EULER_CONFIG_FACTOR_SCALE);

            maxLtv = scaledCollateralFactor.mulWadDown(scaledBorrowFactor);
        }
    }

    /**
     * @notice Fetches collateral and debt amounts for each protocol in the input list
     * @param _protocolIds An array of protocol identifiers for which to fetch the data
     * @param _account The account for which to fetch the data
     * @return collateralPositions An array of collateral positions for each protocol in the input list
     * @return debtPositions An array of debt positions for each protocol in the input list
     */

    function getCollateralAndDebtPositions(Protocol[] calldata _protocolIds, address _account)
        external
        view
        returns (uint256[] memory collateralPositions, uint256[] memory debtPositions)
    {
        collateralPositions = new uint256[](_protocolIds.length);
        debtPositions = new uint256[](_protocolIds.length);

        for (uint8 i = 0; i < _protocolIds.length; i++) {
            collateralPositions[i] = getCollateral(_protocolIds[i], _account);
            debtPositions[i] = getDebt(_protocolIds[i], _account);
        }
    }
}
