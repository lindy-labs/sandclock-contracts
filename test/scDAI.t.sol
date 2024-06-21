// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";

import {Constants as C} from "../src/lib/Constants.sol";
import {ILendingPool} from "../src/interfaces/aave-v2/ILendingPool.sol";
import {IProtocolDataProvider} from "../src/interfaces/aave-v2/IProtocolDataProvider.sol";
import {IAdapter} from "../src/steth/IAdapter.sol";
import {SparkScDaiAdapter} from "../src/steth/scDai-adapters/SparkScDaiAdapter.sol";
import {scSDAI} from "../src/steth/scSDAI.sol";
import {scDAI} from "../src/steth/scDAI.sol";

import {scWETH} from "../src/steth/scWETH.sol";
import {ISwapRouter} from "../src/interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {PriceConverter} from "../src/steth/PriceConverter.sol";
import {Swapper} from "../src/steth/Swapper.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import "../src/errors/scErrors.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {MainnetAddresses as M} from "../script/base/MainnetAddresses.sol";

contract scDAITest is Test {
    using Address for address;
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);

    WETH weth;
    ERC4626 sDai;
    ERC20 dai;

    scWETH wethVault = scWETH(payable(M.SCWETHV2));
    scSDAI scsDAI;
    scDAI vault;

    SparkScDaiAdapter spark;
    Swapper swapper;
    PriceConverter priceConverter;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(19832667);

        sDai = ERC4626(C.SDAI);
        dai = ERC20(C.DAI);
        weth = WETH(payable(C.WETH));
        spark = new SparkScDaiAdapter();

        _deployAndSetUpScsDai();

        vault = new scDAI(scsDAI);
    }

    function testDeposit(uint256 amount) public {
        amount = bound(amount, 1e15, 100000000e18);
        deal(address(dai), address(this), amount);

        dai.approve(address(vault), amount);

        vault.deposit(amount, address(this));

        assertEq(vault.balanceOf(address(this)), amount, "scDAI shares");
        assertEq(scsDAI.balanceOf(address(this)), 0, "scsDAI shares to user");
        assertEq(scsDAI.balanceOf(address(vault)), sDai.convertToShares(amount), "scsDAI shares to scDAI");

        assertApproxEqRel(vault.totalAssets(), amount, 1e10, "totalAssets");
    }

    function testWithdraw_Redeem(uint256 amount) public {
        amount = bound(amount, 1e10, 100000000e18);
        deal(address(dai), address(this), amount);

        dai.approve(address(vault), amount);
        vault.deposit(amount, address(this));

        uint256 withdrawAmount = amount / 2;

        vault.withdraw(withdrawAmount, address(this), address(this));

        assertApproxEqRel(dai.balanceOf(address(this)), withdrawAmount, 1e10, "dai after withdraw");
        assertApproxEqRel(vault.totalAssets(), amount - withdrawAmount, 1e10, "totalAssets");

        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        assertApproxEqRel(dai.balanceOf(address(this)), amount, 1e10, "dai after full redeem");
        assertEq(vault.balanceOf(address(this)), 0, "scDAI shares not zero");
        assertApproxEqRel(vault.totalAssets(), 1, 1e10, "totalAssets after redeem");
    }

    function _deployAndSetUpScsDai() internal {
        priceConverter = new PriceConverter(address(this));
        swapper = new Swapper();

        scsDAI = new scSDAI(address(this), keeper, wethVault, priceConverter, swapper);

        scsDAI.addAdapter(spark);

        // set vault eth balance to zero
        vm.deal(address(scsDAI), 0);
        // set float percentage to 0 for most tests
        scsDAI.setFloatPercentage(0);
        // assign keeper role to deployer
        scsDAI.grantRole(scsDAI.KEEPER_ROLE(), address(this));
    }
}
