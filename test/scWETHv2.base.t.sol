// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";

import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {Errors} from "aave-v3/protocol/libraries/helpers/Errors.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {Constants as C} from "../src/lib/Constants.sol";
import {scWETHv2} from "../src/steth/scWETHv2.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
import {IProtocolFeesCollector} from "../src/interfaces/balancer/IProtocolFeesCollector.sol";
import {AggregatorV3Interface} from "../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {sc4626} from "../src/sc4626.sol";
import {BaseV2Vault} from "../src/steth/BaseV2Vault.sol";
import {scWETHv2Helper} from "./helpers/scWETHv2Helper.sol";
import "../src/errors/scErrors.sol";

import {IAdapter} from "../src/steth/IAdapter.sol";
import {AaveV3ScWethAdapter} from "../src/steth/scWethV2-adapters/AaveV3ScWethAdapter.sol";
import {CompoundV3ScWethAdapter} from "../src/steth/scWethV2-adapters/CompoundV3ScWethAdapter.sol";
import {EulerScWethAdapter} from "../src/steth/scWethV2-adapters/EulerScWethAdapter.sol";
import {Swapper} from "../src/steth/Swapper.sol";
import {PriceConverter} from "../src/steth/PriceConverter.sol";
import {MockAdapter} from "./mocks/adapters/MockAdapter.sol";

contract scWETHv2Base is Test {
    uint256 baseFork;
    uint256 blockNumber = 13629397;

    address admin = address(this);
    scWETHv2 vault;
    scWETHv2Helper vaultHelper;
    PriceConverter priceConverter;
    uint256 initAmount = 100e18;

    uint256 maxLtv;
    WETH weth;
    // ILido stEth;
    IwstETH wstEth;
    // AggregatorV3Interface public stEThToEthPriceFeed;
    uint256 minimumFloatAmount;

    mapping(IAdapter => uint256) targetLtv;

    uint256 aaveV3AdapterId;
    IAdapter aaveV3Adapter;

    uint256 flashLoanFeePercent;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);
    address constant treasury = address(0x07);
    uint256 boundMinimum = 1.5 ether; // below this amount, aave doesn't count it as collateral

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_BASE"));
        vm.selectFork(baseFork);
        vm.rollFork(blockNumber);

        priceConverter = new PriceConverter(address(this));
        vault = _deployVaultWithDefaultParams();
        vaultHelper = new scWETHv2Helper(vault, priceConverter);

        weth = WETH(payable(address(vault.asset())));
        // stEth = ILido(C.STETH);
        wstEth = IwstETH(C.BASE_WSTETH);
        // stEThToEthPriceFeed = AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED);
        minimumFloatAmount = vault.minimumFloatAmount();

        // set vault eth balance to zero
        vm.deal(address(vault), 0);

        _setupAdapters();

        targetLtv[aaveV3Adapter] = 0.7e18;
    }

    function _setupAdapters() internal {
        // add adaptors
        aaveV3Adapter = new AaveV3ScWethAdapter();

        vault.addAdapter(aaveV3Adapter);

        aaveV3AdapterId = aaveV3Adapter.id();
    }

    function _deployVaultWithDefaultParams() internal returns (scWETHv2) {
        return new scWETHv2(admin, keeper, WETH(payable(C.BASE_WETH)), new Swapper(), priceConverter);
    }

    function testDeploy() public {
        console.log("vault address: ", address(vault));
        assertEq(address(vault), address(0x0));
    }
}
