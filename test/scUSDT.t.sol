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
import {scUSDT, scUSDTPriceConverter, scUSDTSwapper, AaveV3ScUsdtAdapter} from "../src/steth/scUSDT.sol";

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

contract scUSDTTest is Test {
    using Address for address;
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);

    WETH weth;
    ERC20 usdt;

    scWETH wethVault = scWETH(payable(M.SCWETHV2));
    scUSDT vault;

    AaveV3ScUsdtAdapter aaveV3Adapter;
    Swapper swapper;
    PriceConverter priceConverter;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(20287837);

        usdt = ERC20(C.USDT);
        weth = WETH(payable(C.WETH));
        aaveV3Adapter = new AaveV3ScUsdtAdapter();

        _deployAndSetUpVault();
    }

    function test_constructor() public {
        assertEq(address(vault.asset()), C.USDT);
        assertEq(address(vault.targetToken()), address(weth), "target token");
        assertEq(address(vault.targetVault()), address(wethVault), "weth vault");
        assertEq(address(vault.priceConverter()), address(priceConverter), "price converter");
        assertEq(address(vault.swapper()), address(swapper), "swapper");

        assertEq(weth.allowance(address(vault), address(vault.targetVault())), type(uint256).max, "scWETH allowance");
    }

    /////////////////////////////////// INTERNAL METHODS ////////////////////

    function _deployAndSetUpVault() internal {
        priceConverter = new scUSDTPriceConverter();
        swapper = new scUSDTSwapper();

        vault = new scUSDT(address(this), keeper, priceConverter, swapper);

        vault.addAdapter(aaveV3Adapter);

        // set vault eth balance to zero
        vm.deal(address(vault), 0);
        // set float percentage to 0 for most tests
        vault.setFloatPercentage(0);
        // assign keeper role to deployer
        vault.grantRole(vault.KEEPER_ROLE(), address(this));
    }

    function _assertCollateralAndDebt(uint256 _protocolId, uint256 _expectedCollateral, uint256 _expectedDebt)
        internal
    {
        uint256 collateral = vault.getCollateral(_protocolId);
        uint256 debt = vault.getDebt(_protocolId);
        string memory protocolName = _protocolIdToString(_protocolId);

        assertApproxEqAbs(collateral, _expectedCollateral, 1, string(abi.encodePacked("collateral on ", protocolName)));
        assertApproxEqAbs(debt, _expectedDebt, 1, string(abi.encodePacked("debt on ", protocolName)));
    }

    function _protocolIdToString(uint256 _protocolId) public view returns (string memory) {
        if (_protocolId == aaveV3Adapter.id()) {
            return "Aave V3";
        }

        revert("unknown protocol");
    }
}
