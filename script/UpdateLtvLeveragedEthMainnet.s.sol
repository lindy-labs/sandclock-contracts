// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {scWETH} from "../src/steth/scWETH.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {Constants as C} from "../src/lib/Constants.sol";
import {DataTypes} from "aave-v3/protocol/libraries/types/DataTypes.sol";
import {WadRayMath} from "aave-v3/protocol/libraries/math/WadRayMath.sol";

import "forge-std/Script.sol";

contract UpdateLtvLeveragedEthMainnet is Script {
    using WadRayMath for uint128;

    address keeper = vm.envAddress("KEEPER");
    scWETH vault = scWETH(payable(vm.envAddress("scWETH")));
    IPool aaveV3Pool = IPool(C.AAVE_V3_POOL);

    uint256 bestLtv = 0.85e18;
    uint256 lowestLtv = 1e8;

    function run() external {
        // get Lido Interest (with 18 decimals)
        uint256 lidoInterest = 0; // TODO

        // get AaveV3 borrow rate
        DataTypes.ReserveData memory reserveData = aaveV3Pool.getReserveData(C.WETH);
        // (with 18 decimals)
        uint256 borrowInterest = reserveData.currentVariableBorrowRate.rayToWad();

        console.log("Borrow Interest", borrowInterest);
        console.log("Lido Interest", lidoInterest);

        if (borrowInterest > lidoInterest) {
            vault.applyNewTargetLtv(lowestLtv);
            vault.harvest();

            console.log("Applied new Target Ltv", lowestLtv);

            return;
        }

        if (vault.getLtv() < bestLtv) {
            vault.applyNewTargetLtv(bestLtv);
            console.log("Applied new Target Ltv", bestLtv);
        }
    }
}
