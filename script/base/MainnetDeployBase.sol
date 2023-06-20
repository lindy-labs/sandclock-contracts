// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {CREATE3Script} from "../base/CREATE3Script.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

import {Constants as C} from "../../src/lib/Constants.sol";
import {ISwapRouter} from "../../src/interfaces/uniswap/ISwapRouter.sol";
import {sc4626} from "../../src/sc4626.sol";
import {scWETHv2} from "../../src/steth/scWETHv2.sol";
import {scUSDCv2} from "../../src/steth/scUSDCv2.sol";
import {Swapper} from "../../src/steth/Swapper.sol";
import {PriceConverter} from "../../src/steth/PriceConverter.sol";
import {AaveV3Adapter as scWethAaveV3Adapter} from "../../src/steth/scWethV2-adapters/AaveV3Adapter.sol";
import {CompoundV3Adapter as scWethCompoundV3Adapter} from "../../src/steth/scWethV2-adapters/CompoundV3Adapter.sol";
import {AaveV3Adapter as scUsdcAaveV3Adapter} from "../../src/steth/scUsdcV2-adapters/AaveV3Adapter.sol";
import {AaveV2Adapter as scUsdcAaveV2Adapter} from "../../src/steth/scUsdcV2-adapters/AaveV2Adapter.sol";

abstract contract MainnetDeployBase is CREATE3Script {
    uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
    address deployerAddress = vm.addr(deployerPrivateKey);
    address keeper = vm.envAddress("KEEPER");

    WETH weth = WETH(payable(C.WETH));
    ERC20 usdc = ERC20(C.USDC);

    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function _transferAdminRoleToMultisig(AccessControl _contract, address _currentAdmin) internal {
        _contract.grantRole(_contract.DEFAULT_ADMIN_ROLE(), C.MULTISIG);
        _contract.revokeRole(_contract.DEFAULT_ADMIN_ROLE(), _currentAdmin);
    }

    function _deposit(sc4626 _vault, uint256 _amount) internal {
        _vault.asset().approve(address(_vault), _amount);
        _vault.deposit(_amount, deployerAddress);
    }

    function _swapWethForUsdc(uint256 _amount) internal {
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

        ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER).exactInputSingle(params);
    }
}
