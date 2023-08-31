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
import {IAdapter} from "../../src/steth/IAdapter.sol";

contract scWETHv2RebalanceTest is Test {
    using FixedPointMathLib for uint256;
    using Address for address;

    uint256 mainnetFork;

    scWETHv2RebalanceTestHarness script;
    scWETHv2 vault;
    WETH weth = WETH(payable(C.WETH));

    IAdapter morphoAdapter;
    IAdapter compoundV3Adapter;

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18018649);
        script = new scWETHv2RebalanceTestHarness();
        vault = script.vault();

        morphoAdapter = script.morphoAdapter();
        compoundV3Adapter = script.compoundV3Adapter();
    }

    function testScriptInvestsFloat() public {
        uint256 amount = 1.5 ether;
        vault.deposit{value: amount}(address(this));

        uint256 investAmount = weth.balanceOf(address(vault)) - vault.minimumFloatAmount();

        bytes memory swapData =
            hex"6af479b2000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000023636b7d513f00000000000000000000000000000000000000000000000000001ecc3994a250ec080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002bc02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000647f39c581f595b53c5cb19bd0b3f8da6c935e2ca0000000000000000000000000000000000000000000869584cd000000000000000000000000588ebf90cce940403c2d3650519313ed5c414cc200000000000000000000000000000000da5461b1fad9fdc20d00ab71a0fb35b6";
        script.setDemoSwapData(swapData); // setting the demo swap data only for the test since the block number is set for the test but zeroEx api returns swapData for the most recent block

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
            investAmount.mulWadDown(script.MORPHO_ALLOCATION_PERCENT()),
            0.006e18,
            "morpho allocation not correct"
        );
        assertApproxEqRel(
            compoundDeposited,
            investAmount.mulWadDown(script.COMPOUNDV3_ALLOCATION_PERCENT()),
            0.006e18,
            "compound allocation not correct"
        );

        assertApproxEqRel(
            script.allocationPercent(morphoAdapter),
            script.MORPHO_ALLOCATION_PERCENT(),
            0.005e18,
            "morpho allocationPercent not correct"
        );

        assertApproxEqRel(
            script.allocationPercent(compoundV3Adapter),
            script.COMPOUNDV3_ALLOCATION_PERCENT(),
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

    function testScriptAlsoReinvestsProfitsUsingZeroExSwap() public {
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));

        bytes memory swapData =
            hex"415565b0000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca00000000000000000000000000000000000000000000000027131c0509b5900000000000000000000000000000000000000000000000000022029f5b1ccae845800000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000003800000000000000000000000000000000000000000000000000000000000000021000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000002e000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca0000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000002a000000000000000000000000000000000000000000000000000000000000002a000000000000000000000000000000000000000000000000000000000000002600000000000000000000000000000000000000000000000027131c0509b590000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002a000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000254d6176657269636b56310000000000000000000000000000000000000000000000000000000000027131c0509b5900000000000000000000000000000000000000000000000000022029f5b1ccae845800000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000040000000000000000000000000bbf1ee38152e9d8e3470dc47947eaa65dca949130000000000000000000000000eb1c92f9f5ec9d817968afddb4b46c564cdedbe000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000869584cd000000000000000000000000588ebf90cce940403c2d3650519313ed5c414cc200000000000000000000000000000000077c5db4e041b450f855f8047b3186e6";
        script.setDemoSwapData(swapData); // setting the demo swap data only for the test since the block number is set for the test but zeroEx api returns swapData for the most recent block

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

        swapData =
            hex"415565b0000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca00000000000000000000000000000000000000000000000031b42b9470c264806000000000000000000000000000000000000000000000002b42ef9a5d0c11ccc00000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000003800000000000000000000000000000000000000000000000000000000000000021000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000002e000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000000000000000000000007f39c581f595b53c5cb19bd0b3f8da6c935e2ca0000000000000000000000000000000000000000000000000000000000000014000000000000000000000000000000000000000000000000000000000000002a000000000000000000000000000000000000000000000000000000000000002a000000000000000000000000000000000000000000000000000000000000002600000000000000000000000000000000000000000000000031b42b9470c264806000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002a000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000254d6176657269636b56310000000000000000000000000000000000000000000000000000000000031b42b9470c264806000000000000000000000000000000000000000000000002b42ef9a5d0c11ccc00000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000040000000000000000000000000bbf1ee38152e9d8e3470dc47947eaa65dca949130000000000000000000000000eb1c92f9f5ec9d817968afddb4b46c564cdedbe000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001c000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000a00000000000000000000000000000000000000000000000000000000000000002000000000000000000000000c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2000000000000000000000000eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee0000000000000000000000000000000000000000000000000000000000000000869584cd000000000000000000000000588ebf90cce940403c2d3650519313ed5c414cc200000000000000000000000000000000c7ef570251a9f81c32db8d085a932337";
        script.setDemoSwapData(swapData);

        script.run();

        assertApproxEqRel(altv, script.getLtv(morphoAdapter), 0.0015e18, "morpho ltvs not reset after reinvest");
        assertApproxEqRel(
            compoundLtv, script.getLtv(compoundV3Adapter), 0.0015e18, "compound ltvs not reset after reinvest"
        );
        assertApproxEqRel(ltv, script.getLtv(), 0.005e18, "net ltv not reset after reinvest");

        // assertEq(weth.balanceOf(address(vault)), vault.minimumFloatAmount(), "float not invested");
    }

    function testScriptDisinvestsInProtocolsWithLoss() public {
        // invest first
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));
        script.run();

        uint256 updatedMorphoTargetLtv = script.MORPHO_TARGET_LTV() - 0.02e18;
        uint256 updatedCompoundV3TargetLtv = script.COMPOUNDV3_TARGET_LTV() - 0.02e18;

        // now decrease target ltvs to simulate loss
        script.updateMorphoTargetLtv(updatedMorphoTargetLtv);
        script.updateCompoundV3TargetLtv(updatedCompoundV3TargetLtv);

        uint256 assets = vault.totalAssets();
        uint256 leverage = script.getLeverage();

        script.run();

        assertApproxEqRel(
            script.getLtv(morphoAdapter), updatedMorphoTargetLtv, 0.005e18, "morpho ltv not updated after loss"
        );

        assertApproxEqRel(
            script.getLtv(compoundV3Adapter),
            updatedCompoundV3TargetLtv,
            0.005e18,
            "compound ltv not updated after loss"
        );

        assertLt(
            weth.balanceOf(address(vault)), vault.minimumFloatAmount().mulWadDown(1.01e18), "weth dust after disinvest"
        );
        assertApproxEqRel(vault.totalAssets(), assets, 0.001e18, "disinvest must not change total assets");
        assertGe(leverage, script.getLeverage(), "leverage not decreased after disinvest");
    }

    function testScriptDisinvestsAndInvests() public {
        // invest first
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));
        script.run();

        // simulate loss in morpho and profit in compound
        uint256 updatedMorphoTargetLtv = script.MORPHO_TARGET_LTV() - 0.02e18;
        uint256 updatedCompoundV3TargetLtv = script.COMPOUNDV3_TARGET_LTV() + 0.02e18;

        script.updateMorphoTargetLtv(updatedMorphoTargetLtv);
        script.updateCompoundV3TargetLtv(updatedCompoundV3TargetLtv);

        script.run();
    }

    //////////////////////////////////// INTERNAL METHODS ///////////////////////////////////////

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

// TODO
// Add tests f
// investing when there is no underlying float in the contract (just reinvesting profits)
// For other variations of allocation Percents

contract scWETHv2RebalanceTestHarness is scWETHv2Rebalance {
    bytes testSwapData;

    function getSwapData(uint256, address, address) public view override returns (bytes memory swapData) {
        return testSwapData;
    }

    function setDemoSwapData(bytes memory _swapData) external {
        testSwapData = _swapData;
    }

    function updateMorphoTargetLtv(uint256 _ltv) external {
        targetLtv[morphoAdapter] = _ltv;
    }

    function updateCompoundV3TargetLtv(uint256 _ltv) external {
        targetLtv[compoundV3Adapter] = _ltv;
    }

    function updateAaveV3TargetLtv(uint256 _ltv) external {
        targetLtv[aaveV3Adapter] = _ltv;
    }

    function updateMorphoAllocationPercent(uint256 _percent) external {
        MORPHO_ALLOCATION_PERCENT = _percent;
    }

    function updateCompoundV3AllocationPercent(uint256 _percent) external {
        COMPOUNDV3_ALLOCATION_PERCENT = _percent;
    }

    function updateAaveV3AllocationPercent(uint256 _percent) external {
        AAVEV3_ALLOCATION_PERCENT = _percent;
    }
}
