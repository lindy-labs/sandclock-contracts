// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {Constants as C} from "../../lib/Constants.sol";
import {IAdapter} from "../IAdapter.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";
import {IMorpho} from "../../interfaces/morpho/IMorpho.sol";

/**
 * @title Morpho Lending Protocol Adapter
 * @notice Facilitates lending and borrowing for the Morpho lending protocol
 * @notice Morpho is a peer 2 peer lending protocol which uses Aave v3 under the hood as last resort
 */
contract MorphoAaveV3ScUsdcAdapter is IAdapter {
    ERC20 constant usdc = ERC20(C.USDC);
    WETH constant weth = WETH(payable(C.WETH));

    // address of the Aave v3 pool data provider contract (used to get the max ltv)
    IPoolDataProvider public constant aaveV3PoolDataProvider = IPoolDataProvider(C.AAVE_V3_POOL_DATA_PROVIDER);
    // address of the Morpho contract
    IMorpho public constant morpho = IMorpho(C.MORPHO);

    /// @inheritdoc IAdapter
    uint256 public constant id = 4;

    /// @inheritdoc IAdapter
    function setApprovals() external override {
        usdc.approve(address(morpho), type(uint256).max);
        weth.approve(address(morpho), type(uint256).max);
    }

    /// @inheritdoc IAdapter
    function revokeApprovals() external override {
        usdc.approve(address(morpho), 0);
        weth.approve(address(morpho), 0);
    }

    /// @inheritdoc IAdapter
    function supply(uint256 _amount) external override {
        morpho.supplyCollateral(address(usdc), _amount, address(this));
    }

    /// @inheritdoc IAdapter
    function borrow(uint256 _amount) external override {
        morpho.borrow(address(weth), _amount, address(this), address(this), 0);
    }

    /// @inheritdoc IAdapter
    function repay(uint256 _amount) external override {
        morpho.repay(address(weth), _amount, address(this));
    }

    /// @inheritdoc IAdapter
    function withdraw(uint256 _amount) external override {
        morpho.withdrawCollateral(address(usdc), _amount, address(this), address(this));
    }

    /// @inheritdoc IAdapter
    function claimRewards(bytes calldata _data) external override {
        address[] memory assets = abi.decode(_data, (address[]));
        morpho.claimRewards(assets, address(this));
    }

    /// @inheritdoc IAdapter
    function getCollateral(address _account) external view override returns (uint256) {
        return morpho.collateralBalance(address(usdc), _account);
    }

    /// @inheritdoc IAdapter
    function getDebt(address _account) external view override returns (uint256) {
        return morpho.borrowBalance(address(weth), _account);
    }

    /// @inheritdoc IAdapter
    function getMaxLtv() external view override returns (uint256) {
        (, uint256 ltv,,,,,,,,) = aaveV3PoolDataProvider.getReserveConfigurationData(address(usdc));

        // ltv is returned as a percentage with 2 decimals (e.g. 80% = 8000) so we need to multiply by 1e14
        // same as the maxLtv as for aave v3 since it's being used as the underlying protocol for morpho
        return ltv * 1e14;
    }
}
