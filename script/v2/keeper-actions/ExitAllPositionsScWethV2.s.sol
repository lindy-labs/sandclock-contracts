// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {Constants as C} from "../../../src/lib/Constants.sol";
import {MainnetAddresses as MA} from "../../base/MainnetAddresses.sol";
import {scWETHv2} from "../../../src/steth/scWETHv2.sol";
import {PriceConverter} from "../../../src/steth/priceConverter/PriceConverter.sol";
import {scWETHv2Helper} from "../../../test/helpers/scWETHv2Helper.sol";

/**
 * @notice Exit all positions and withdraw all funds as WETH to the vault
 * cmd
 * first run a local anvil node using " anvil -f YOUR_RPC_URL"
 * Then run the script using
 * forge script script/v2/manual-runs/scWETHv2ExitAllPositions.s.sol --rpc-url http://127.0.0.1:8545
 */
contract ExitAllPositionsScWethV2 is Script, scWETHv2Helper {
    using FixedPointMathLib for uint256;

    uint256 keeperPrivateKey = uint256(vm.envOr("KEEPER_PRIVATE_KEY", bytes32(0x00)));
    WETH weth = WETH(payable(C.WETH));

    constructor() scWETHv2Helper(scWETHv2(payable(MA.SCWETHV2)), PriceConverter(MA.PRICE_CONVERTER)) {}

    function run() external {
        address keeper = keeperPrivateKey != 0 ? vm.addr(keeperPrivateKey) : MA.KEEPER;

        _logs("-----------Before Exit----------------\n");

        vm.startBroadcast(keeper);

        _withdrawAll();

        _logs("------------After Exit------------------\n");

        vm.stopBroadcast();
    }

    function _withdrawAll() internal {
        uint256 collateralInWeth = priceConverter.wstEthToEth(vault.totalCollateral());
        uint256 debt = vault.totalDebt();

        if (collateralInWeth > debt) {
            vault.withdrawToVault(collateralInWeth - debt);
        }
    }

    function _logs(string memory _msg) internal view {
        console2.log(_msg);

        uint256 collateralInWeth = priceConverter.wstEthToEth(vault.totalCollateral());
        uint256 debt = vault.totalDebt();

        console2.log("\n Total Collateral %s weth", collateralInWeth);
        console2.log("\n Total Debt %s weth", debt);
        console2.log("\n Invested Amount %s weth", collateralInWeth - debt);
        console2.log("\n Total Assets %s weth", vault.totalAssets());
        console2.log("\n Float %s weth", weth.balanceOf(address(vault)));
    }
}
