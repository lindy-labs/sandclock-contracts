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
import {scUSDS} from "../src/steth/scUSDS.sol";
import {IDaiUsds} from "../src/interfaces/sky/IDaiUsds.sol";
import {scSDAI} from "../src/steth/scSDAI.sol";
import {scDAI} from "../src/steth/scDAI.sol";
import {SDaiWethSwapper} from "../src/steth/swapper/SDaiWethSwapper.sol";
import {SDaiWethPriceConverter} from "../src/steth/priceConverter/SDaiWethPriceConverter.sol";
import {SparkScSDaiAdapter} from "../src/steth/scSDai-adapters/SparkScSDaiAdapter.sol";

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
    scDAI scDai;
    scUSDS vault;

    AaveV3ScUsdtAdapter aaveV3Adapter;
    ISinglePairSwapper swapper;
    ISinglePairPriceConverter priceConverter;

    uint256 pps;

    constructor() {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(20825479);

        usds = ERC20(C.USDS);
        weth = WETH(payable(C.WETH));

        pps = wethVault.totalAssets().divWadDown(wethVault.totalSupply());

        _deployAndSetUpScDai();

        vault = new scUSDS(ERC4626(address(scDai)));
    }

    function test_DaiUsdsConverter() public {
        IDaiUsds daiUsdsConverter = IDaiUsds(C.DAI_USDS_CONVERTER);

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

    function test_deposit(uint256 amount) public {
        amount = bound(amount, 1e10, 100000000e18);
        deal(address(usds), address(this), amount);

        usds.approve(address(vault), amount);

        vault.deposit(amount, address(this));

        assertEq(vault.balanceOf(address(this)), amount, "scUSDS shares");
        assertEq(scDai.balanceOf(address(this)), 0, "scDAI shares to user");
        assertEq(scDai.balanceOf(address(vault)), amount, "amount deposited in scDAI");

        assertApproxEqRel(vault.totalAssets(), amount, 1e10, "totalAssets");
    }

    function test_withdraw_redeem() public {
        uint256 amount = 10_000e18;
        deal(address(usds), address(this), amount);

        usds.approve(address(vault), amount);
        vault.deposit(amount, address(this));

        uint256 withdrawAmount = amount / 2;

        vault.withdraw(withdrawAmount, address(this), address(this));

        assertApproxEqRel(usds.balanceOf(address(this)), withdrawAmount, 1e10, "usds after withdraw");
        assertApproxEqRel(vault.totalAssets(), amount - withdrawAmount, 1e10, "totalAssets");

        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        assertApproxEqRel(usds.balanceOf(address(this)), amount, 1e10, "usds after full redeem");
        assertEq(vault.balanceOf(address(this)), 0, "scUSDS shares not zero");
    }
    /////////////////////////////// INTERNAL METHODS /////////////////////////////////////////////////

    function _deployAndSetUpScDai() internal {
        priceConverter = new SDaiWethPriceConverter();
        swapper = new SDaiWethSwapper();

        scSDAI scsDAI = new scSDAI(address(this), keeper, wethVault, priceConverter, swapper);

        scsDAI.addAdapter(new SparkScSDaiAdapter());

        // set vault eth balance to zero
        vm.deal(address(scsDAI), 0);
        // set float percentage to 0 for most tests
        scsDAI.setFloatPercentage(0);
        // assign keeper role to deployer
        scsDAI.grantRole(scsDAI.KEEPER_ROLE(), address(this));

        scDai = new scDAI(scsDAI);
    }
}
