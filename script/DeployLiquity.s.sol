// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {SwapperLib} from "src/steth/swapper/SwapperLib.sol";
import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {MainnetDeployBase} from "script/base/MainnetDeployBase.sol";
import {Constants as C} from "src/lib/Constants.sol";
import {scLiquity} from "src/liquity/scLiquity.sol";

/**
 * Mainnet deployment script for scLiquity vault.
 */
contract DeployLiquity is MainnetDeployBase {
    ERC20 constant lusd = ERC20(C.LUSD);

    function run() external returns (scLiquity vault) {
        vm.startBroadcast(deployerAddress);

        vault = new scLiquity(deployerAddress, keeper, lusd);

        // get some LUSD and make the initial deposit (addressing share inflation)
        weth.deposit{value: 0.01 ether}();

        uint256 usdcAmount = SwapperLib._uniswapSwapExactInput(address(weth), address(usdc), 0.01 ether, 0, 500); // 0.05% pool fee
        uint256 lusdAmount = SwapperLib._uniswapSwapExactInput(address(usdc), address(lusd), usdcAmount, 0, 500); // 0.05% pool fee

        _deposit(vault, lusdAmount);

        _setTreasury(vault, MainnetAddresses.TREASURY);

        _transferAdminRoleToMultisig(vault, deployerAddress);

        vm.stopBroadcast();
    }
}
