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

contract DeployScript is CREATE3Script {
    uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
    address deployerAddress = vm.addr(deployerPrivateKey);
    address keeper = vm.envAddress("KEEPER");

    WETH weth = WETH(payable(C.WETH));
    ERC20 usdc = ERC20(C.USDC);

    constructor() CREATE3Script(vm.envString("VERSION")) {}

    function run() external returns (scWETHv2 scWethV2, scUSDCv2 scUsdcV2) {
        vm.startBroadcast(deployerPrivateKey);

        Swapper swapper = new Swapper();
        console2.log("Swapper:", address(swapper));
        PriceConverter priceConverter = new PriceConverter(deployerAddress);
        console2.log("PriceConverter:", address(priceConverter));

        transferAdminRoleToMultisig(priceConverter, deployerAddress);

        scWethV2 = _deployScWethV2(priceConverter, swapper);

        scUsdcV2 = _deployScUsdcV2(scWethV2, priceConverter, swapper);

        vm.stopBroadcast();
    }

    function _deployScWethV2(PriceConverter _priceConverter, Swapper _swapper) internal returns (scWETHv2 vault) {
        vault = new scWETHv2(deployerAddress, keeper, 0.99e18, weth, _swapper, _priceConverter);

        // deploy & add adapters
        scWethAaveV3Adapter aaveV3Adapter = new scWethAaveV3Adapter();
        vault.addAdapter(aaveV3Adapter);

        scWethCompoundV3Adapter compoundV3Adapter = new scWethCompoundV3Adapter();
        vault.addAdapter(compoundV3Adapter);

        weth.deposit{value: 0.01 ether}(); // wrap 0.01 ETH into WETH
        _deposit(vault, 0.01 ether); // 0.01 WETH

        transferAdminRoleToMultisig(vault, deployerAddress);

        console2.log("scWethV2 vault:", address(vault));
        console2.log("scWethV2 AaveV3Adapter:", address(aaveV3Adapter));
        console2.log("scWETHV2 CompoundV3Adapter:", address(compoundV3Adapter));
    }

    function _deployScUsdcV2(scWETHv2 _wethVault, PriceConverter _priceConveter, Swapper _swapper)
        internal
        returns (scUSDCv2 vault)
    {
        vault = new scUSDCv2(deployerAddress, keeper, _wethVault, _priceConveter, _swapper);

        // deploy & add adapters
        scUsdcAaveV3Adapter aaveV3Adapter = new scUsdcAaveV3Adapter();
        vault.addAdapter(aaveV3Adapter);

        scUsdcAaveV2Adapter aaveV2Adapter = new scUsdcAaveV2Adapter();
        vault.addAdapter(aaveV2Adapter);

        _swapWethForUsdc(0.01 ether);
        _deposit(vault, usdc.balanceOf(deployerAddress)); // 0.01 ether worth of USDC

        transferAdminRoleToMultisig(vault, deployerAddress);

        console2.log("scUSDCv2 vault:", address(vault));
        console2.log("scUSDCv2 AaveV3Adapter:", address(aaveV3Adapter));
        console2.log("scUSDCv2 CompoundV3Adapter:", address(aaveV2Adapter));
    }

    function transferAdminRoleToMultisig(AccessControl _contract, address _currentAdmin) internal {
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
