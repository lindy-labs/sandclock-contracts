// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {CREATE3Script} from "../base/CREATE3Script.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {MainnetAddresses} from "./MainnetAddresses.sol";
import {Constants as C} from "../../src/lib/Constants.sol";
import {ISwapRouter} from "../../src/interfaces/uniswap/ISwapRouter.sol";
import {sc4626} from "../../src/sc4626.sol";

/**
 * Mainnet base deployment file that handles deployment.
 */
abstract contract MainnetDeployBase is CREATE3Script {
    using SafeTransferLib for ERC20;

    uint256 deployerPrivateKey;
    address deployerAddress;
    address keeper;
    address multisig;

    WETH weth = WETH(payable(C.WETH));
    ERC20 usdc = ERC20(C.USDC);

    constructor() {
        _init();
    }

    function _init() internal virtual {
        deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        deployerAddress = vm.addr(deployerPrivateKey);
        keeper = vm.envAddress("KEEPER");
        multisig = vm.envAddress("MULTISIG");
    }

    function _transferAdminRoleToMultisig(AccessControl _contract, address _currentAdmin) internal {
        _contract.grantRole(_contract.DEFAULT_ADMIN_ROLE(), multisig);
        _contract.revokeRole(_contract.DEFAULT_ADMIN_ROLE(), _currentAdmin);
    }

    function _setTreasury(sc4626 _vault, address _treasury) internal {
        _vault.setTreasury(_treasury);
    }

    function _deposit(sc4626 _vault, uint256 _amount) internal virtual {
        _vault.asset().approve(address(_vault), _amount);
        _vault.deposit(_amount, deployerAddress);
    }

    function _swapWethForUsdc(uint256 _amount) internal returns (uint256 amountOut) {
        weth.deposit{value: _amount}();

        weth.approve(C.UNISWAP_V3_SWAP_ROUTER, _amount);

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(usdc),
            fee: 500, // 0.05%
            recipient: deployerAddress,
            deadline: block.timestamp + 1000,
            amountIn: _amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        amountOut = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER).exactInputSingle(params);
    }
}
