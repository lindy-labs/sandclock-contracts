// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {scWETHv2} from "../steth/scWETHv2.sol";
import {PriceConverter} from "../steth/PriceConverter.sol";
import {IAdapter} from "../steth/IAdapter.sol";

// TODO: as of my understanding, this contract came to life because of one primary reason, to reduce the scWETHv2 contract size. With the new design, i think this can also be removed since the scWETHv2 will become fairly small and simple
// @title helper contract for just the external view methods to be used by the backend
contract scWETHv2Helper {
    using FixedPointMathLib for uint256;

    scWETHv2 vault;
    PriceConverter priceConverter;

    constructor(scWETHv2 _vault, PriceConverter _priceConverter) {
        vault = _vault;
        priceConverter = _priceConverter;
    }

    /// @notice returns the weth debt of the vault in a particularly protocol (in terms of weth)
    /// @param adapter the address of the adapter contract of the protocol
    function getDebt(IAdapter adapter) public view returns (uint256) {
        return adapter.getDebt(address(vault));
    }

    /// @notice returns the wstEth deposited of the vault in a particularly protocol (in terms of weth)
    /// @param adapter the address of the adapter contract of the protocol
    function getCollateral(IAdapter adapter) public view returns (uint256) {
        return priceConverter.wstEthToEth(adapter.getCollateral(address(vault)));
    }

    // TODO: would prefer to use this function instead of the one above because collateral is in wstEth and not weth
    function getCollateral2(IAdapter adapter) public view returns (uint256) {
        return adapter.getCollateral(address(vault));
    }

    /// @notice returns the net leverage that the strategy is using right now (1e18 = 100%)
    function getLeverage() public view returns (uint256) {
        uint256 collateral = vault.totalCollateral();
        return collateral > 0 ? collateral.divWadUp(collateral - vault.totalDebt()) : 0;
    }

    /// @notice returns the loan to value ration of the vault contract in a particular protocol
    /// @param adapter the address of the adapter contract of the protocol
    function getLtv(IAdapter adapter) public view returns (uint256) {
        uint256 collateral = getCollateral(adapter);

        if (collateral == 0) return 0;

        return getDebt(adapter).divWadDown(getCollateral(adapter));
    }

    /// @notice method to get the assets deposited in a particular lending market (in terms of weth)
    function getAssets(IAdapter adapter) external view returns (uint256) {
        return getCollateral(adapter) - getDebt(adapter);
    }

    /// @notice returns the net LTV (Loan to Value) at which the vault has borrowed till now (1e18 = 100%)
    function getLtv() public view returns (uint256 ltv) {
        uint256 collateral = vault.totalCollateral();
        if (collateral > 0) {
            // getDebt / totalSupplied
            ltv = vault.totalDebt().divWadUp(collateral);
        }
    }

    /// @notice returns the asset allocation (in percent) in a particular protocol (1e18 = 100%)
    /// @param adapter the address of the adapter contract of the protocol
    function allocationPercent(IAdapter adapter) external view returns (uint256) {
        return (getCollateral(adapter) - getDebt(adapter)).divWadDown(vault.totalCollateral() - vault.totalDebt());
    }
}
