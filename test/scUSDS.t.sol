// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Constants as C} from "../src/lib/Constants.sol";
import {ILendingPool} from "../src/interfaces/aave-v2/ILendingPool.sol";
import {IProtocolDataProvider} from "../src/interfaces/aave-v2/IProtocolDataProvider.sol";
import {IAdapter} from "../src/steth/IAdapter.sol";
import {AaveV3ScUsdtAdapter} from "../src/steth/scUsdt-adapters/AaveV3ScUsdtAdapter.sol";
import {UsdtWethPriceConverter} from "../src/steth/priceConverter/UsdtWethPriceConverter.sol";

import {scWETH} from "../src/steth/scWETH.sol";
import {scCrossAssetYieldVault} from "../src/steth/scCrossAssetYieldVault.sol";
import {ISwapRouter} from "../src/interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {PriceConverter} from "../src/steth/priceConverter/PriceConverter.sol";
import {ISinglePairPriceConverter} from "../src/steth/priceConverter/ISinglePairPriceConverter.sol";
import {ISinglePairSwapper} from "../src/steth/swapper/ISinglePairSwapper.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import "../src/errors/scErrors.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {MainnetAddresses as M} from "../script/base/MainnetAddresses.sol";
import {UsdtWethSwapper} from "../src/steth/swapper/UsdtWethSwapper.sol";

contract scUSDSTest is Test {
    using Address for address;
    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);

    WETH weth;
    ERC20 usds;
    ERC20 dai = ERC20(C.DAI);

    scWETH wethVault = scWETH(payable(M.SCWETHV2));
    // scUSDS vault;

    AaveV3ScUsdtAdapter aaveV3Adapter;
    ISinglePairSwapper swapper;
    ISinglePairPriceConverter priceConverter;

    uint256 pps;

    DaiUsds daiUsdsConverter;

    constructor() {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(20825479);

        usds = ERC20(C.USDS);
        weth = WETH(payable(C.WETH));
        // aaveV3Adapter = new AaveV3ScUsdtAdapter();

        pps = wethVault.totalAssets().divWadDown(wethVault.totalSupply());

        daiUsdsConverter = DaiUsds(0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A);
    }

    function test_DaiUsdsConverter() public {
        uint256 daiAmount = 100e18;
        deal(address(dai), address(this), daiAmount);

        assertEq(usds.balanceOf(address(this)), 0, "initial usds amount");
        assertEq(dai.balanceOf(address(this)), daiAmount, "initial dai amount");

        dai.safeApprove(address(daiUsdsConverter), daiAmount);

        daiUsdsConverter.daiToUsds(address(this), daiAmount);

        assertEq(usds.balanceOf(address(this)), daiAmount, "usds transfer error");
        assertEq(dai.balanceOf(address(this)), 0, "dai transfer error");

        // transfer dai to usds
        usds.safeApprove(address(daiUsdsConverter), daiAmount);
        daiUsdsConverter.usdsToDai(address(this), daiAmount);

        assertEq(usds.balanceOf(address(this)), 0, "usds transfer error 2");
        assertEq(dai.balanceOf(address(this)), daiAmount, "dai transfer error 2");
    }
}

interface DaiUsds {
    function daiToUsds(address usr, uint256 wad) external;

    function usdsToDai(address usr, uint256 wad) external;
}
