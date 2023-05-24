// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {IAdapter} from "./IAdapter.sol";

contract AaveV3Adapter is IAdapter {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;

    // Aave v3 pool contract
    IPool public constant pool = IPool(0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2);
    // Aave v3 "aEthUSDC" token (supply token)
    ERC20 public constant aUsdc = ERC20(0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c);
    // Aave v3 "variableDebtEthWETH" token (variable debt token)
    ERC20 public constant dWeth = ERC20(0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE);

    uint8 public constant id = 1;

    function setApprovals() external override {
        ERC20(C.USDC).safeApprove(address(pool), type(uint256).max);
        WETH(payable(C.WETH)).safeApprove(address(pool), type(uint256).max);
    }

    function revokeApprovals() external override {
        ERC20(C.USDC).safeApprove(address(pool), 0);
        WETH(payable(C.WETH)).safeApprove(address(pool), 0);
    }

    function supply(uint256 _amount) external override {
        pool.supply(address(C.USDC), _amount, address(this), 0);
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
