// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";
import {IAdapter} from "../IAdapter.sol";

/**
 * @title Aave v3 Lending Protocol Adapter
 * @notice Facilitates lending and borrowing for the Aave v3 lending protocol
 */
contract AaveV3ScUsdtAdapter is IAdapter {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;

    ERC20 public constant usdt = ERC20(C.USDT);
    WETH public constant weth = WETH(payable(C.WETH));

    // Aave v3 pool contract
    IPool public constant pool = IPool(C.AAVE_V3_POOL);
    // Aave v3 pool data provider contract
    IPoolDataProvider public constant aaveV3PoolDataProvider = IPoolDataProvider(C.AAVE_V3_POOL_DATA_PROVIDER);
    // Aave v3 "aEthUSDT" token (supply token)
    ERC20 public constant aUsdt = ERC20(C.AAVE_V3_AUSDT_TOKEN);
    // Aave v3 "variableDebtEthWETH" token (variable debt token)
    ERC20 public constant dWeth = ERC20(C.AAVE_V3_VAR_DEBT_WETH_TOKEN);

    /// @inheritdoc IAdapter
    uint256 public constant override id = 1;

    /// @inheritdoc IAdapter
    function setApprovals() external override {
        usdt.safeApprove(address(pool), type(uint256).max);
        weth.safeApprove(address(pool), type(uint256).max);
    }

    /// @inheritdoc IAdapter
    function revokeApprovals() external override {
        usdt.safeApprove(address(pool), 0);
        weth.safeApprove(address(pool), 0);
    }

    /// @inheritdoc IAdapter
    function supply(uint256 _amount) external override {
        pool.supply(address(usdt), _amount, address(this), 0);
    }

    /// @inheritdoc IAdapter
    function borrow(uint256 _amount) external override {
        pool.borrow(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
    }

    /// @inheritdoc IAdapter
    function repay(uint256 _amount) external override {
        pool.repay(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
    }

    /// @inheritdoc IAdapter
    function withdraw(uint256 _amount) external override {
        pool.withdraw(address(usdt), _amount, address(this));
    }

    /// @inheritdoc IAdapter
    function claimRewards(bytes calldata) external pure override {
        revert("not applicable");
    }

    /// @inheritdoc IAdapter
    function getCollateral(address _account) external view override returns (uint256) {
        return aUsdt.balanceOf(_account);
    }

    /// @inheritdoc IAdapter
    function getDebt(address _account) external view override returns (uint256) {
        return dWeth.balanceOf(_account);
    }

    /// @inheritdoc IAdapter
    function getMaxLtv() external view override returns (uint256) {
        (, uint256 ltv,,,,,,,,) = aaveV3PoolDataProvider.getReserveConfigurationData(address(usdt));

        // ltv is returned as a percentage with 2 decimals (e.g. 80% = 8000) so we need to multiply by 1e14
        return ltv * 1e14;
    }
}
