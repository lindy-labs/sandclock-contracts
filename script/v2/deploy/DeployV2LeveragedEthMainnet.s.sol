// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";

import {MainnetDeployBase} from "script/base/MainnetDeployBase.sol";
import {Constants as C} from "src/lib/Constants.sol";
import {ISwapRouter} from "src/interfaces/uniswap/ISwapRouter.sol";
import {sc4626} from "src/sc4626.sol";
import {scWETHv2} from "src/steth/scWETHv2.sol";
import {scUSDCv2} from "src/steth/scUSDCv2.sol";
import {Swapper} from "src/steth/swapper/Swapper.sol";
import {PriceConverter} from "src/steth/priceConverter/PriceConverter.sol";
import {UsdcWethPriceConverter} from "src/steth/priceConverter/UsdcWethPriceConverter.sol";
import {AaveV3ScWethAdapter} from "src/steth/scWethV2-adapters/AaveV3ScWethAdapter.sol";
import {CompoundV3ScWethAdapter} from "src/steth/scWethV2-adapters/CompoundV3ScWethAdapter.sol";
import {MorphoAaveV3ScWethAdapter} from "src/steth/scWethV2-adapters/MorphoAaveV3ScWethAdapter.sol";
import {AaveV3ScUsdcAdapter} from "src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter} from "src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {UsdcWethSwapper} from "src/steth/swapper/UsdcWethSwapper.sol";

contract DeployV2LeveragedEthMainnet is MainnetDeployBase {
    function run() external returns (scWETHv2 scWethV2, scUSDCv2 scUsdcV2) {
        vm.startBroadcast(deployerPrivateKey);

        Swapper swapper = new Swapper();
        UsdcWethSwapper scUsdcSwapper = new UsdcWethSwapper();
        console2.log("Swapper:", address(swapper));
        PriceConverter priceConverter = new PriceConverter(deployerAddress);
        UsdcWethPriceConverter usdcPriceConverter = new UsdcWethPriceConverter();
        console2.log("PriceConverter:", address(priceConverter));

        _transferAdminRoleToMultisig(priceConverter, deployerAddress);

        scWethV2 = _deployScWethV2(priceConverter, swapper);

        scUsdcV2 = _deployScUsdcV2(scWethV2, usdcPriceConverter, scUsdcSwapper);

        vm.stopBroadcast();
    }

    function _deployScWethV2(PriceConverter _priceConverter, Swapper _swapper) internal returns (scWETHv2 vault) {
        vault = new scWETHv2(deployerAddress, keeper, weth, _swapper, _priceConverter);

        // deploy & add adapters
        AaveV3ScWethAdapter aaveV3Adapter = new AaveV3ScWethAdapter();
        vault.addAdapter(aaveV3Adapter);

        CompoundV3ScWethAdapter compoundV3Adapter = new CompoundV3ScWethAdapter();
        vault.addAdapter(compoundV3Adapter);

        MorphoAaveV3ScWethAdapter morphoAdapter = new MorphoAaveV3ScWethAdapter();
        vault.addAdapter(morphoAdapter);

        weth.deposit{value: 0.01 ether}(); // wrap 0.01 ETH into WETH
        _deposit(vault, 0.01 ether); // 0.01 WETH

        _transferAdminRoleToMultisig(vault, deployerAddress);

        console2.log("scWethV2 vault:", address(vault));
        console2.log("scWethV2 AaveV3Adapter:", address(aaveV3Adapter));
        console2.log("scWETHV2 CompoundV3Adapter:", address(compoundV3Adapter));
        console2.log("scWethV2 MorphoAdapter:", address(morphoAdapter));
    }

    function _deployScUsdcV2(scWETHv2 _wethVault, UsdcWethPriceConverter _priceConveter, UsdcWethSwapper _swapper)
        internal
        returns (scUSDCv2 vault)
    {
        vault = new scUSDCv2(deployerAddress, keeper, _wethVault, _priceConveter, _swapper);

        // deploy & add adapters
        AaveV3ScUsdcAdapter aaveV3Adapter = new AaveV3ScUsdcAdapter();
        vault.addAdapter(aaveV3Adapter);

        AaveV2ScUsdcAdapter aaveV2Adapter = new AaveV2ScUsdcAdapter();
        vault.addAdapter(aaveV2Adapter);

        MorphoAaveV3ScUsdcAdapter morphoAdapter = new MorphoAaveV3ScUsdcAdapter();
        vault.addAdapter(morphoAdapter);

        uint256 usdcAmount = _swapWethForUsdc(0.01 ether);
        _deposit(vault, usdcAmount); // 0.01 ether worth of USDC

        _transferAdminRoleToMultisig(vault, deployerAddress);

        console2.log("scUSDCv2 vault:", address(vault));
        console2.log("scUSDCv2 AaveV3Adapter:", address(aaveV3Adapter));
        console2.log("scUSDCv2 AaveV2Adapter:", address(aaveV2Adapter));
        console2.log("scUSDCv2 MorphoAaveV3Adapter:", address(morphoAdapter));
    }
}
