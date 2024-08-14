// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Script.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

import {MainnetAddresses} from "../../base/MainnetAddresses.sol";
import {scWETHv2Keeper} from "src/steth/scWETHv2Keeper.sol";
import {scWETHv2} from "src/steth/scWETHv2.sol";
import {PriceConverter} from "src/steth/PriceConverter.sol";
import {IScETHPriceConverter} from "src/steth/priceConverter/IPriceConverter.sol";
import {Constants as C} from "src/lib/Constants.sol";

contract InvestScWETHv2Keeper is Script {
    using FixedPointMathLib for uint256;

    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    bool public useAaveV3 = true;
    uint256 public aaveV3AllocationPercent = 1e18; // 1e18 = 100%
    uint256 public aaveV3TargetLtv = 0.9e18; // 0.9e18 = 90%

    bool public useCompoundV3 = false;
    uint256 public compoundV3AllocationPercent = 0;
    uint256 public compoundV3TargetLtv = 0;

    /*//////////////////////////////////////////////////////////////*/

    uint256[] adapterIds;
    uint256[] allocations;
    uint256[] targetLtvs;

    scWETHv2 vault;
    scWETHv2Keeper keeper;
    IScETHPriceConverter priceConverter;
    address operator;

    function run() external {
        console2.log("--- ScWETHv2KeeperInvest script running ---");

        // set up
        _init();
        _buildInvestParams();
        _logState("\t\t--- Initial State ---");

        // Rebalance the scWETHv2 vault

        (, uint256 flashLoanAmount, bytes[] memory multicallData) =
            keeper.calculateInvestParams(adapterIds, allocations, targetLtvs);

        vm.startBroadcast(operator);
        keeper.invest(flashLoanAmount, multicallData, 1); // 1 is for aave v3 adapter id
        vm.stopBroadcast();

        _logState("\t\t--- Final State ---");
        console2.log("--- ScWETHv2KeeperInvest script done --");
    }

    function _init() internal {
        // TODO: update mainnetAddresses after keeper contract is deployed
        // vm.envOr("SCWETHV2_KEEPER", MainnetAddresses.SCWETHV2_KEEPER)
        keeper = scWETHv2Keeper(vm.envAddress("SCWETHV2_KEEPER"));
        vault = keeper.target();
        priceConverter = vault.converter();
        uint256 operatorKey = vm.envUint("OPERATOR_PRIVATE_KEY");
        operator = vm.rememberKey(operatorKey);
    }

    function _buildInvestParams() internal {
        if (useAaveV3) {
            adapterIds.push(1);
            allocations.push(aaveV3AllocationPercent);
            targetLtvs.push(aaveV3TargetLtv);
        }

        if (useCompoundV3) {
            adapterIds.push(2);
            allocations.push(compoundV3AllocationPercent);
            targetLtvs.push(compoundV3TargetLtv);
        }

        console2.log("\t-- invest parameters --");
        for (uint256 i = 0; i < adapterIds.length; i++) {
            console2.log("adapterId:\t", adapterIds[i]);
            console2.log("allocation:\t", allocations[i]);
            console2.log("targetLtv:\t", targetLtvs[i]);
        }
        console2.log("--------------------------------------------\n");
    }

    function _logState(string memory _heading) internal view {
        console2.log(_heading);

        uint256 collateral = vault.totalCollateral();
        uint256 collateralInWeth = priceConverter.wstEthToEth(collateral);
        uint256 debt = vault.totalDebt();
        uint256 invested = collateralInWeth - debt;
        uint256 leverage = invested > 0 ? collateralInWeth.divWadUp(invested) : 0;

        console2.log("total collateral\t\t", collateral);
        console2.log("total collateral in weth\t", collateralInWeth);
        console2.log("total debt\t\t\t", debt);
        console2.log("invested amount\t\t", collateralInWeth - debt);
        console2.log("total assets\t\t\t", vault.totalAssets());
        console2.log("net leverage\t\t\t", leverage);
        console2.log("total ltv\t\t\t", debt.divWadUp(collateralInWeth));
        console2.log("float\t\t\t\t", IERC20(C.WETH).balanceOf(address(vault)));
        console2.log("wstEth balance\t\t", IERC20(C.WSTETH).balanceOf(address(vault)));

        console2.log("--------------------------------------------\n");
    }
}
