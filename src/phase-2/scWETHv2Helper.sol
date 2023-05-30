// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {scWETHv2} from "./scWETHv2.sol";
import {OracleLib} from "./OracleLib.sol";
import {IAdapter} from "../scWeth-adapters/IAdapter.sol";

// @title helper contract for just the external view methods to be used by the backend
contract scWETHv2Helper {
    using FixedPointMathLib for uint256;

    scWETHv2 vault;
    OracleLib oracleLib;

    constructor(scWETHv2 _vault, OracleLib _oracleLib) {
        vault = _vault;
        oracleLib = _oracleLib;
    }

    function getDebt(IAdapter adapter) public view returns (uint256) {
        return adapter.getDebt(address(vault));
    }

    function getCollateral(IAdapter adapter) public view returns (uint256) {
        return oracleLib.wstEthToEth(adapter.getCollateral(address(vault)));
    }

    /// @notice returns the net leverage that the strategy is using right now (1e18 = 100%)
    function getLeverage() public view returns (uint256) {
        uint256 collateral = vault.totalCollateral();
        return collateral > 0 ? collateral.divWadUp(collateral - vault.totalDebt()) : 0;
    }

    function getLtv(IAdapter adapter) public view returns (uint256) {
        return getDebt(adapter).divWadDown(getCollateral(adapter));
    }

    /// @notice method to get the assets deposited in a particular lending market (in terms of weth)
    function getAssets(IAdapter adapter) external view returns (uint256) {
        return getCollateral(adapter) - getDebt(adapter);
    }

    /// @notice returns the net LTV at which we have borrowed till now (1e18 = 100%)
    function getLtv() public view returns (uint256 ltv) {
        uint256 collateral = vault.totalCollateral();
        if (collateral > 0) {
            // getDebt / totalSupplied
            ltv = vault.totalDebt().divWadUp(collateral);
        }
    }

    function allocationPercent(IAdapter adapter) external view returns (uint256) {
        return (getCollateral(adapter) - getDebt(adapter)).divWadDown(vault.totalCollateral() - vault.totalDebt());
    }
}
