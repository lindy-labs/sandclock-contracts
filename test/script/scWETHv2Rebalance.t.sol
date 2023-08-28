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
import {WETH} from "solmate/tokens/WETH.sol";

import {Constants as C} from "../../src/lib/Constants.sol";
import {scWETHv2Rebalance} from "../../script/v2/manual-runs/scWETHv2Rebalance.s.sol";
import {scWETHv2} from "../../src/steth/scWETHv2.sol";
import {scWETHv2StrategyParams as Params} from "../../script/base/scWETHv2StrategyParams.sol";
import {IAdapter} from "../../src/steth/IAdapter.sol";

contract scWETHv2RebalanceTest is Test {
    using FixedPointMathLib for uint256;
    using Address for address;

    uint256 mainnetFork;

    scWETHv2Rebalance script;
    scWETHv2 vault;
    WETH weth = WETH(payable(C.WETH));

    IAdapter morphoAdapter;
    IAdapter compoundV3Adapter;

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18014113);
        script = new scWETHv2Rebalance();
        vault = script.vault();

        morphoAdapter = script.morphoAdapter();
        compoundV3Adapter = script.compoundV3Adapter();
    }

    function testScriptInvestsFloat() public {
        uint256 amount = 1.5 ether;
        vault.deposit{value: amount}(address(this));

        uint256 investAmount = weth.balanceOf(address(vault)) - vault.minimumFloatAmount();

        script.run();

        uint256 totalCollateral = script.priceConverter().wstEthToEth(vault.totalCollateral());
        uint256 totalDebt = vault.totalDebt();
        assertApproxEqRel(totalCollateral - totalDebt, investAmount, 0.01e18, "totalAssets not equal amount");
        assertEq(vault.totalInvested(), investAmount, "totalInvested not updated");

        uint256 morphoDeposited = script.getCollateralInWeth(morphoAdapter) - vault.getDebt(morphoAdapter.id());
        uint256 compoundDeposited =
            script.getCollateralInWeth(compoundV3Adapter) - vault.getDebt(compoundV3Adapter.id());

        assertApproxEqRel(
            morphoDeposited,
            investAmount.mulWadDown(Params.MORPHO_ALLOCATION_PERCENT),
            0.006e18,
            "morpho allocation not correct"
        );
        assertApproxEqRel(
            compoundDeposited,
            investAmount.mulWadDown(Params.COMPOUNDV3_ALLOCATION_PERCENT),
            0.006e18,
            "compound allocation not correct"
        );

        assertApproxEqRel(
            script.allocationPercent(morphoAdapter),
            Params.MORPHO_ALLOCATION_PERCENT,
            0.005e18,
            "morpho allocationPercent not correct"
        );

        assertApproxEqRel(
            script.allocationPercent(compoundV3Adapter),
            Params.COMPOUNDV3_ALLOCATION_PERCENT,
            0.005e18,
            "compound allocationPercent not correct"
        );

        assertApproxEqRel(
            script.getLtv(morphoAdapter), script.targetLtv(morphoAdapter), 0.005e18, "morpho ltv not correct"
        );
        assertApproxEqRel(
            script.getLtv(compoundV3Adapter), script.targetLtv(compoundV3Adapter), 0.005e18, "compound ltv not correct"
        );
    }

    function testScriptAlsoReinvestsProfits() public {
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));

        script.run();

        uint256 altv = script.getLtv(morphoAdapter);
        uint256 compoundLtv = script.getLtv(compoundV3Adapter);
        uint256 ltv = script.getLtv();

        _simulate_stEthStakingInterest(365 days, 1.071e18);

        assertLt(script.getLtv(), ltv, "ltv must decrease after simulated profits");
        assertLt(script.getLtv(morphoAdapter), altv, "morpho ltv must decrease after simulated profits");

        assertLt(script.getLtv(compoundV3Adapter), compoundLtv, "compound ltv must decrease after simulated profits");

        // a new deposit (putting some float into the vault)
        vault.deposit{value: amount}(address(this));

        script.run();

        assertApproxEqRel(altv, script.getLtv(morphoAdapter), 0.0015e18, "morpho ltvs not reset after reinvest");
        assertApproxEqRel(
            compoundLtv, script.getLtv(compoundV3Adapter), 0.0015e18, "compound ltvs not reset after reinvest"
        );
        assertApproxEqRel(ltv, script.getLtv(), 0.005e18, "net ltv not reset after reinvest");

        assertEq(weth.balanceOf(address(vault)), vault.minimumFloatAmount(), "float not invested");
    }

    function _simulate_stEthStakingInterest(uint256 timePeriod, uint256 stEthStakingInterest) internal {
        // fast forward time to simulate supply and borrow interests
        vm.warp(block.timestamp + timePeriod);
        uint256 prevBalance = read_storage_uint(C.STETH, keccak256(abi.encodePacked("lido.Lido.beaconBalance")));
        vm.store(
            C.STETH,
            keccak256(abi.encodePacked("lido.Lido.beaconBalance")),
            bytes32(prevBalance.mulWadDown(stEthStakingInterest))
        );
    }

    function read_storage_uint(address addr, bytes32 key) internal view returns (uint256) {
        return abi.decode(abi.encode(vm.load(addr, key)), (uint256));
    }
}
