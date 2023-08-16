// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Surl} from "surl/Surl.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";

import {Constants as C} from "../../../src/lib/Constants.sol";
import {ISwapRouter} from "../../../src/interfaces/uniswap/ISwapRouter.sol";
import {sc4626} from "../../../src/sc4626.sol";
import {scWETHv2} from "../../../src/steth/scWETHv2.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {Swapper} from "../../../src/steth/Swapper.sol";
import {PriceConverter} from "../../../src/steth/PriceConverter.sol";
import {AaveV3ScWethAdapter as scWethAaveV3Adapter} from "../../../src/steth/scWethV2-adapters/AaveV3ScWethAdapter.sol";
import {CompoundV3ScWethAdapter as scWethCompoundV3Adapter} from
    "../../../src/steth/scWethV2-adapters/CompoundV3ScWethAdapter.sol";
import {AaveV3ScUsdcAdapter as scUsdcAaveV3Adapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter as scUsdcAaveV2Adapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {MainnetDeployBase} from "../../base/MainnetDeployBase.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";
import {scWETHv2Helper} from "../../../test/helpers/scWETHv2Helper.sol";
import {scWETHv2Utils} from "../utils/scWETHv2Utils.sol";

/**
 * invests underlying float in the vault
 * and at the same time also reinvests profits made till now by the vault

 * cmd
 * first run a local anvil node using " anvil -f YOUR_RPC_URL"
 * Then run the script using
 * forge script script/v2/manual-runs/scWETHv2Rebalance.s.sol -rpc-url http://127.0.0.1:8545 --ffi
 */
contract scWETHv2Rebalance is scWETHv2Utils {
    using FixedPointMathLib for uint256;
    using Surl for *;
    using Strings for *;

    uint256 keeperPrivateKey = uint256(vm.envBytes32("KEEPER_PRIVATE_KEY"));

    address keeper = vm.envAddress("KEEPER");

    address localWhale = 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266;

    function run() external {
        swapData(1e18);
        // _test();
        // _main();
    }

    function swapData(uint _amount) internal {
        string memory url = string(abi.encodePacked("https://api.0x.org/swap/v1/quote?buyToken=0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0&sellToken=WETH&sellAmount=", _amount.toString()));

        string[] memory headers = new string[](1);
        headers[0] = string(abi.encodePacked("0x-api-key: ", vm.envString('ZEROX_API_KEY')));
        (uint256 status, bytes memory data) = url.get(headers);

        require(status == 200, "0x GET request Failed");

        console2.logBytes(data);
    }

    function _test() internal {
        vm.startBroadcast(localWhale);
        vault.deposit{value: 1.5 ether}(localWhale);
        vm.stopBroadcast();

        vm.startBroadcast(keeper);

        // _invest();
        // _logs();

        vm.stopBroadcast();
    }

    function _main() internal {
        vm.startBroadcast(keeperPrivateKey);

        _invest();
        _logs();

        vm.stopBroadcast();
    }

    function _logs() internal view {
        uint256 collateralInWeth = priceConverter.wstEthToEth(vault.totalCollateral());
        uint256 debt = vault.totalDebt();
        console2.log("\n Total Collateral %s weth", collateralInWeth);
        console2.log("\n Total Debt %s weth", debt);
        console2.log("\n Invested Amount %s weth", collateralInWeth - debt);
        console2.log("\n Total Assets %s weth", vault.totalAssets());
        console2.log("\n Net Leverage", getLeverage());
        console2.log("\n Net LTV", debt.divWadUp(collateralInWeth));
    }
}
