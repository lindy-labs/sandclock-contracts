// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {ILendingPool} from "../../interfaces/aave-v2/ILendingPool.sol";
import {IAdapter} from "./IAdapter.sol";

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

    function revokeApprovals() external override {
        ERC20(C.USDC).safeApprove(address(pool), 0);
        WETH(payable(C.WETH)).safeApprove(address(pool), 0);
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
