// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {IAdapter} from "../IAdapter.sol";

contract AaveV3ScWethAdapter is IAdapter {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;

    IPool public constant pool = IPool(C.BASE_AAVE_V3_POOL);
    ERC20 public constant aWstEth = ERC20(C.BASE_AAVE_V3_AWSTETH_TOKEN);
    ERC20 public constant dWeth = ERC20(C.BASE_AAVE_V3_VAR_DEBT_WETH_TOKEN);

    uint256 public constant id = 1;

    function setApprovals() external override {
        ERC20(C.BASE_WSTETH).safeApprove(address(pool), type(uint256).max);
        WETH(payable(C.BASE_WETH)).safeApprove(address(pool), type(uint256).max);

        pool.setUserEMode(C.AAVE_EMODE_ID);
    }

    function revokeApprovals() external override {
        ERC20(C.BASE_WSTETH).safeApprove(address(pool), 0);
        WETH(payable(C.BASE_WETH)).safeApprove(address(pool), 0);
    }

    function supply(uint256 _amount) external override {
        pool.supply(address(C.BASE_WSTETH), _amount, address(this), 0);
    }

    function borrow(uint256 _amount) external override {
        pool.borrow(address(C.BASE_WETH), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
    }

    function repay(uint256 _amount) external override {
        pool.repay(address(C.BASE_WETH), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
    }

    function withdraw(uint256 _amount) external override {
        pool.withdraw(address(C.BASE_WSTETH), _amount, address(this));
    }

    function claimRewards(bytes calldata data) external override {}

    function getCollateral(address _account) external view override returns (uint256) {
        return aWstEth.balanceOf(_account);
    }

    function getDebt(address _account) external view override returns (uint256) {
        return dWeth.balanceOf(_account);
    }

    function getMaxLtv() external view override returns (uint256) {
        return uint256(pool.getEModeCategoryData(C.AAVE_EMODE_ID).ltv) * 1e14;
    }
}
