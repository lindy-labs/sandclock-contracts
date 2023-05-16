// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {scWETHv2} from "./scWETHv2.sol";
import {LendingMarketManager} from "./LendingMarketManager.sol";
import {OracleLib} from "./OracleLib.sol";

// @title helper contract for just the external view methods to be used by the backend
contract scWETHv2Helper {
    using FixedPointMathLib for uint256;

    scWETHv2 vault;
    LendingMarketManager lendingManager;
    OracleLib oracleLib;

    constructor(scWETHv2 _vault, LendingMarketManager _lendingManager, OracleLib _oracleLib) {
        vault = _vault;
        lendingManager = _lendingManager;
        oracleLib = _oracleLib;
    }

    function getDebt(LendingMarketManager.Protocol protocol) public view returns (uint256) {
        return lendingManager.getDebt(protocol, address(vault));
    }

    function getCollateral(LendingMarketManager.Protocol protocol) public view returns (uint256) {
        return oracleLib.wstEthToEth(lendingManager.getCollateral(protocol, address(vault)));
    }

    /// @notice returns the net leverage that the strategy is using right now (1e18 = 100%)
    function getLeverage() public view returns (uint256) {
        uint256 coll = vault.totalCollateral();
        return coll > 0 ? coll.divWadUp(coll - vault.totalDebt()) : 0;
    }

    function getLtv(LendingMarketManager.Protocol protocol) public view returns (uint256) {
        return lendingManager.getDebt(protocol, address(vault)).divWadDown(
            oracleLib.wstEthToEth(lendingManager.getCollateral(protocol, address(vault)))
        );
    }

    /// @notice method to get the assets deposited in a particular lending market (in terms of weth)
    function getAssets(LendingMarketManager.Protocol protocol) external view returns (uint256) {
        return oracleLib.wstEthToEth(lendingManager.getCollateral(protocol, address(vault)))
            - lendingManager.getDebt(protocol, address(vault));
    }

    /// @notice returns the net LTV at which we have borrowed till now (1e18 = 100%)
    function getLtv() public view returns (uint256 ltv) {
        uint256 collateral = vault.totalCollateral();
        if (collateral > 0) {
            // getDebt / totalSupplied
            ltv = vault.totalDebt().divWadUp(collateral);
        }
    }

    function allocationPercent(LendingMarketManager.Protocol protocol) external view returns (uint256) {
        return (
            oracleLib.wstEthToEth(lendingManager.getCollateral(protocol, address(vault)))
                - lendingManager.getDebt(protocol, address(vault))
        ).divWadDown(vault.totalCollateral() - vault.totalDebt());
    }
}
