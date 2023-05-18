// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {
    InvalidTargetLtv,
    InvalidSlippageTolerance,
    InvalidFloatPercentage,
    InvalidFlashLoanCaller,
    VaultNotUnderwater,
    NoProfitsToSell,
    FlashLoanAmountZero,
    PriceFeedZeroAddress,
    EndUsdcBalanceTooLow
} from "../../errors/scErrors.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {IVault} from "../../interfaces/balancer/IVault.sol";
import {ISwapRouter} from "../../interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../../interfaces/chainlink/AggregatorV3Interface.sol";
import {IFlashLoanRecipient} from "../../interfaces/balancer/IFlashLoanRecipient.sol";
import {scUSDCBase} from "../scUSDCBase.sol";
import {UsdcWethLendingManager} from "../UsdcWethLendingManager.sol";

import {IPool} from "aave-v3/interfaces/IPool.sol";
import {ILendingPool} from "../../interfaces/aave-v2/ILendingPool.sol";

import {IEulerMarkets, IEulerEToken, IEulerDToken} from "lib/euler-interfaces/contracts/IEuler.sol";

interface IAdapter {
    function id() external returns (uint8);
    function setApprovals() external;
    function supply(uint256 amount) external;
    function borrow(uint256 amount) external;
    function repay(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function getCollateral(address account) external view returns (uint256);
    function getDebt(address account) external view returns (uint256);
}

contract AaveV3Adapter is IAdapter {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;

    IPool public constant pool = IPool(C.AAVE_POOL);
    ERC20 public constant aUsdc = ERC20(C.AAVE_AUSDC_TOKEN);
    ERC20 public constant dWeth = ERC20(C.AAVAAVE_VAR_DEBT_WETH_TOKEN);

    uint8 public constant id = 1;

    function setApprovals() external override {
        ERC20(C.USDC).safeApprove(address(pool), type(uint256).max);
        WETH(payable(C.WETH)).safeApprove(address(pool), type(uint256).max);
    }

    function supply(uint256 _amount) external override {
        console2.log("inside adaptor supply");
        console2.log("_amount", _amount);
        console2.log("address(this)", address(this));
        pool.supply(address(C.USDC), _amount, address(this), 0);
    }

    function borrow(uint256 _amount) external override {
        console2.log("inside adaptor borrow");
        pool.borrow(address(C.WETH), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
    }

    function repay(uint256 _amount) external override {
        pool.repay(address(C.WETH), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
    }

    function withdraw(uint256 _amount) external override {
        pool.withdraw(address(C.USDC), _amount, address(this));
    }

    function getCollateral(address _account) external view override returns (uint256) {
        return aUsdc.balanceOf(_account);
    }

    function getDebt(address _account) external view override returns (uint256) {
        return dWeth.balanceOf(_account);
    }
}

contract AaveV2Adapter is IAdapter {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;

    ILendingPool public constant pool = ILendingPool(C.AAVE_V2_LENDING_POOL);
    ERC20 public constant aUsdc = ERC20(C.AAVE_V2_AUSDC_TOKEN);
    ERC20 public constant dWeth = ERC20(C.AAVE_V2_VAR_DEBT_WETH_TOKEN);

    uint8 public constant id = 2;

    function setApprovals() external override {
        ERC20(C.USDC).safeApprove(address(pool), type(uint256).max);
        WETH(payable(C.WETH)).safeApprove(address(pool), type(uint256).max);
    }

    function supply(uint256 _amount) external override {
        pool.deposit(address(C.USDC), _amount, address(this), 0);
    }

    function borrow(uint256 _amount) external override {
        pool.borrow(address(C.WETH), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
    }

    function repay(uint256 _amount) external override {
        pool.repay(address(C.WETH), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
    }

    function withdraw(uint256 _amount) external override {
        pool.withdraw(address(C.USDC), _amount, address(this));
    }

    function getCollateral(address _account) external view override returns (uint256) {
        return aUsdc.balanceOf(_account);
    }

    function getDebt(address _account) external view override returns (uint256) {
        return dWeth.balanceOf(_account);
    }
}

contract EulerAdapter is IAdapter {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;

    address constant protocol = C.EULER_PROTOCOL;
    IEulerMarkets constant markets = IEulerMarkets(C.EULER_MARKETS);
    IEulerEToken constant eUsdc = IEulerEToken(C.EULER_EUSDC_TOKEN);
    IEulerDToken constant dWeth = IEulerDToken(C.EULER_DWETH_TOKEN);
    // rewardsToken: ERC20(C.EULER_REWARDS_TOKEN)

    uint8 public constant id = 3;

    function setApprovals() external override {
        ERC20(C.USDC).safeApprove(protocol, type(uint256).max);
        WETH(payable(C.WETH)).safeApprove(protocol, type(uint256).max);
        markets.enterMarket(0, address(C.USDC));
    }

    function supply(uint256 _amount) external override {
        eUsdc.deposit(0, _amount);
    }

    function borrow(uint256 _amount) external override {
        dWeth.borrow(0, _amount);
    }

    function repay(uint256 _amount) external override {
        dWeth.repay(0, _amount);
    }

    function withdraw(uint256 _amount) external override {
        eUsdc.withdraw(0, _amount);
    }

    function getCollateral(address _account) external view override returns (uint256) {
        return eUsdc.balanceOfUnderlying(_account);
    }

    function getDebt(address _account) external view override returns (uint256) {
        return dWeth.balanceOf(_account);
    }
}
