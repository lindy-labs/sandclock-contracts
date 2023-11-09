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
import {MainnetAddresses} from "../../script/base/MainnetAddresses.sol";
import {RebalanceScWethV2} from "../../script/v2/keeper-actions/RebalanceScWethV2.s.sol";
import {scWETHv2} from "../../src/steth/scWETHv2.sol";
import {IAdapter} from "../../src/steth/IAdapter.sol";

contract RebalanceScWethV2Test is Test {
    using FixedPointMathLib for uint256;
    using Address for address;

    uint256 mainnetFork;

    RebalanceScWethV2TestHarness script;
    scWETHv2 vault;
    WETH weth = WETH(payable(C.WETH));

    IAdapter morphoAdapter;
    IAdapter compoundV3Adapter;
    IAdapter aaveV3Adapter;

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18018649);
        script = new RebalanceScWethV2TestHarness();
        vault = script.vault();

        // update roles to latest accounts
        vm.startPrank(MainnetAddresses.OLD_MULTISIG);
        vault.grantRole(vault.DEFAULT_ADMIN_ROLE(), MainnetAddresses.MULTISIG);
        vault.grantRole(vault.KEEPER_ROLE(), MainnetAddresses.KEEPER);
        vm.stopPrank();

        morphoAdapter = script.morphoAdapter();
        compoundV3Adapter = script.compoundV3Adapter();
        aaveV3Adapter = script.aaveV3Adapter();
    }

    function testScriptInvestsFloat() public {
        uint256 amount = 1.5 ether;
        vault.deposit{value: amount}(address(this));

        uint256 investAmount = _investAmount();

        bytes memory swapData =
            hex"6af479b2000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000023636b7d513f00000000000000000000000000000000000000000000000000001ecc3994a250ec080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002bc02aaa39b223fe8d0a0e5c4f27ead9083c756cc20000647f39c581f595b53c5cb19bd0b3f8da6c935e2ca0000000000000000000000000000000000000000000869584cd000000000000000000000000588ebf90cce940403c2d3650519313ed5c414cc200000000000000000000000000000000da5461b1fad9fdc20d00ab71a0fb35b6";
        script.setDemoSwapData(swapData); // setting the demo swap data only for the test since the block number is set for the test but zeroEx api returns swapData for the most recent block

        script.run();

        assertEq(vault.totalInvested(), investAmount, "totalInvested not updated");

        uint256 totalCollateral = script.priceConverter().wstEthToEth(vault.totalCollateral());
        uint256 totalDebt = vault.totalDebt();
        assertApproxEqRel(totalCollateral - totalDebt, investAmount, 0.01e18, "totalAssets not equal amount");
        assertEq(vault.totalInvested(), investAmount, "totalInvested not updated");

        uint256 morphoDeposited = script.getCollateralInWeth(morphoAdapter) - vault.getDebt(morphoAdapter.id());
        uint256 compoundDeposited =
            script.getCollateralInWeth(compoundV3Adapter) - vault.getDebt(compoundV3Adapter.id());

        assertApproxEqRel(
            morphoDeposited,
            investAmount.mulWadDown(script.morphoInvestableAmountPercent()),
            0.006e18,
            "morpho allocation not correct"
        );
        assertApproxEqRel(
            compoundDeposited,
            investAmount.mulWadDown(script.compoundV3InvestableAmountPercent()),
            0.006e18,
            "compound allocation not correct"
        );

        _assertAllocations(script.morphoInvestableAmountPercent(), script.compoundV3InvestableAmountPercent(), 0);

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
        script = new RebalanceScWethV2TestHarness(); // reset script state

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

        _assertLtvs(altv, compoundLtv, 0);
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

        script = new RebalanceScWethV2TestHarness(); // reset state

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

        _assertLtvs(altv, compoundLtv, 0);

        assertApproxEqRel(ltv, script.getLtv(), 0.005e18, "net ltv not reset after reinvest");

        // assertEq(weth.balanceOf(address(vault)), vault.minimumFloatAmount(), "float not invested");
    }

    function testScriptDisinvestsInProtocolsWithLoss() public {
        // invest first
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));
        uint256 investAmount = _investAmount();
        script.run();

        script = new RebalanceScWethV2TestHarness(); // reset script state

        uint256 updatedMorphoTargetLtv = script.morphoTargetLtv() - 0.02e18;
        uint256 updatedCompoundV3TargetLtv = script.compoundV3TargetLtv() - 0.02e18;

        // now decrease target ltvs to simulate loss
        script.updateMorphoTargetLtv(updatedMorphoTargetLtv);
        script.updateCompoundV3TargetLtv(updatedCompoundV3TargetLtv);

        uint256 assets = vault.totalAssets();
        uint256 leverage = script.getLeverage();

        script.run();

        assertEq(vault.totalInvested(), investAmount, "totalInvested must not change");

        assertLt(
            weth.balanceOf(address(vault)), vault.minimumFloatAmount().mulWadDown(1.01e18), "weth dust after disinvest"
        );
        assertApproxEqRel(vault.totalAssets(), assets, 0.001e18, "disinvest must not change total assets");
        assertGe(leverage, script.getLeverage(), "leverage not increased after disinvest");

        _assertLtvs(updatedMorphoTargetLtv, updatedCompoundV3TargetLtv, 0);
        _assertAllocations(script.morphoInvestableAmountPercent(), script.compoundV3InvestableAmountPercent(), 0);
    }

    function testScriptDisinvestsAndInvests() public {
        // invest first
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));
        uint256 investAmount = _investAmount();
        script.run();

        script = new RebalanceScWethV2TestHarness(); // reset script state

        // simulate loss in morpho and profit in compound
        uint256 updatedMorphoTargetLtv = script.morphoTargetLtv() - 0.02e18;
        uint256 updatedCompoundV3TargetLtv = script.compoundV3TargetLtv() + 0.02e18;

        script.updateMorphoTargetLtv(updatedMorphoTargetLtv);
        script.updateCompoundV3TargetLtv(updatedCompoundV3TargetLtv);

        uint256 assets = vault.totalAssets();

        script.run();

        assertEq(vault.totalInvested(), investAmount, "totalInvested must not change");

        assertApproxEqRel(vault.totalAssets(), assets, 0.001e18, "must not change total assets");

        _assertLtvs(updatedMorphoTargetLtv, updatedCompoundV3TargetLtv, 0);

        _assertAllocations(
            script.adapterAllocationPercent(morphoAdapter), script.adapterAllocationPercent(compoundV3Adapter), 0
        );
    }

    function testScriptInvestsInThreeAndDisinvestInTwo() public {
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));

        uint256 investAmount = _investAmount();

        uint256 morphoAllocation = 0.2e18;
        uint256 compoundV3Allocation = 0.5e18;
        uint256 aaveV3Allocation = 0.3e18;

        // change allocation percents
        script.setMorphoInvestableAmountPercent(morphoAllocation);
        script.setCompoundV3InvestableAmountPercent(compoundV3Allocation);
        script.setAaveV3InvestableAmountPercent(aaveV3Allocation);

        script.run();

        _assertAllocations(morphoAllocation, compoundV3Allocation, aaveV3Allocation);
        _assertLtvs(0.8e18, 0.8e18, 0.8e18);

        script = new RebalanceScWethV2TestHarness(); // reset script state

        // change allocation percents
        script.setMorphoInvestableAmountPercent(morphoAllocation);
        script.setCompoundV3InvestableAmountPercent(compoundV3Allocation);
        script.setAaveV3InvestableAmountPercent(aaveV3Allocation);

        // simulate loss in compound and profit in aave and morpho
        uint256 updatedCompoundV3TargetLtv = script.compoundV3TargetLtv() - 0.02e18;
        uint256 updatedMorphoTargetLtv = script.morphoTargetLtv() + 0.02e18;
        uint256 updatedAaveV3TargetLtv = script.aaveV3TargetLtv() + 0.02e18;

        script.updateMorphoTargetLtv(updatedMorphoTargetLtv);
        script.updateCompoundV3TargetLtv(updatedCompoundV3TargetLtv);
        script.updateAaveV3TargetLtv(updatedAaveV3TargetLtv);

        uint256 assets = vault.totalAssets();

        assertEq(vault.totalInvested(), investAmount, "totalInvested must not change");

        // the script must disinvest in compound and reinvest in aave and morpho
        script.run();

        assertApproxEqRel(vault.totalAssets(), assets, 0.001e18, "must not change total assets");

        _assertLtvs(updatedMorphoTargetLtv, updatedCompoundV3TargetLtv, updatedAaveV3TargetLtv);

        _assertAllocations(morphoAllocation, compoundV3Allocation, aaveV3Allocation);
    }

    function testScriptInvestDepositDisinvest() public {
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));
        uint256 investAmount = _investAmount();
        script.run();

        vault.deposit{value: amount}(address(this));
        investAmount += amount;
        uint256 assets = vault.totalAssets();

        script = new RebalanceScWethV2TestHarness(); // reset script state

        uint256 updatedMorphoTargetLtv = script.morphoTargetLtv() - 0.02e18;
        uint256 updatedCompoundV3TargetLtv = script.compoundV3TargetLtv() - 0.02e18;

        // now decrease target ltvs to simulate loss
        script.updateMorphoTargetLtv(updatedMorphoTargetLtv);
        script.updateCompoundV3TargetLtv(updatedCompoundV3TargetLtv);

        script.run();

        assertEq(vault.totalInvested(), investAmount, "totalInvested must not change");

        assertApproxEqRel(vault.totalAssets(), assets, 0.0015e18, "must not change total assets");

        _assertLtvs(updatedMorphoTargetLtv, updatedCompoundV3TargetLtv, 0);
        _assertAllocations(
            script.adapterAllocationPercent(morphoAdapter), script.adapterAllocationPercent(compoundV3Adapter), 0
        );
    }

    function testDisinvestsEvenIfProtocolIsNotInNextInvest() public {
        // invest in aaveV3 and compound
        // but then increase up aaveV3 allocation to 100% so we only invest in aaveV3 after that.
        // now simulate loss in aaveV3
        // assert that the script disinvests in aaveV3 even though aaveV3 has zero allocation for next invest
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));

        uint256 investAmount = _investAmount();

        uint256 compoundV3Allocation = 0.5e18;
        uint256 aaveV3Allocation = 0.5e18;

        // change allocation percents
        script.setMorphoInvestableAmountPercent(0);
        script.setCompoundV3InvestableAmountPercent(compoundV3Allocation);
        script.setAaveV3InvestableAmountPercent(aaveV3Allocation);

        script.run();

        _assertAllocations(0, compoundV3Allocation, aaveV3Allocation);
        _assertLtvs(0, 0.8e18, 0.8e18);

        script = new RebalanceScWethV2TestHarness(); // reset script state

        // change allocation percents
        script.setCompoundV3InvestableAmountPercent(1e18);
        script.setAaveV3InvestableAmountPercent(0);
        script.setMorphoInvestableAmountPercent(0);

        // simulate loss in  aave
        uint256 updatedAaveV3TargetLtv = script.aaveV3TargetLtv() - 0.04e18;

        script.updateAaveV3TargetLtv(updatedAaveV3TargetLtv);

        uint256 assets = vault.totalAssets();

        // the script must disinvest in compound and reinvest in aave and morpho
        script.run();

        assertEq(vault.totalInvested(), investAmount, "totalInvested must not change");

        assertApproxEqRel(vault.totalAssets(), assets, 0.001e18, "must not change total assets");

        _assertLtvs(0, script.compoundV3TargetLtv(), updatedAaveV3TargetLtv);

        _assertAllocations(0, compoundV3Allocation, aaveV3Allocation);
    }

    function testDisinvestOnlyIfDisinvestThresholdIsCrossed() public {
        // invest first
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));
        script.run();

        uint256 morphoLtv = script.getLtv(morphoAdapter);

        script = new RebalanceScWethV2TestHarness(); // reset script state

        // simulate loss in morpho but not crossing disinvest threshold
        uint256 updatedMorphoTargetLtv = morphoLtv - script.disinvestThreshold() + 0.005e18;

        script.updateMorphoTargetLtv(updatedMorphoTargetLtv);

        script.run();

        // ltv must remain same
        assertEq(script.getLtv(morphoAdapter), morphoLtv, "MORPHO LTV must remain same");
    }

    function testInvestOneAdapter() public {
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));

        uint256 investAmount = _investAmount();

        // change allocation percents
        script.setMorphoInvestableAmountPercent(0);
        script.setCompoundV3InvestableAmountPercent(0);
        script.setAaveV3InvestableAmountPercent(1e18);

        script.run();

        assertEq(vault.totalInvested(), investAmount, "totalInvested not updated");

        uint256 totalCollateral = script.priceConverter().wstEthToEth(vault.totalCollateral());
        uint256 totalDebt = vault.totalDebt();
        assertApproxEqRel(totalCollateral - totalDebt, investAmount, 0.01e18, "totalAssets not equal amount");
        assertEq(vault.totalInvested(), investAmount, "totalInvested not updated");

        uint256 aaveDeposited = script.getCollateralInWeth(aaveV3Adapter) - vault.getDebt(aaveV3Adapter.id());

        assertApproxEqRel(aaveDeposited, investAmount, 0.006e18, "aaveV3 allocation not correct");

        _assertAllocations(0, 0, 1e18);

        assertApproxEqRel(
            script.getLtv(aaveV3Adapter), script.targetLtv(aaveV3Adapter), 0.005e18, "aavev3 ltv not correct"
        );
    }

    function testDisinvestOneAdapter() public {
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));
        uint256 investAmount = _investAmount();

        // change allocation percents
        script.setMorphoInvestableAmountPercent(0);
        script.setCompoundV3InvestableAmountPercent(0);
        script.setAaveV3InvestableAmountPercent(1e18);

        script.run();

        uint256 assets = vault.totalAssets();

        script = new RebalanceScWethV2TestHarness(); // reset script state

        uint256 updatedAaveTargetLtv = script.aaveV3TargetLtv() - 0.04e18;

        // now decrease target ltvs to simulate loss
        script.updateAaveV3TargetLtv(updatedAaveTargetLtv);

        script.run();

        assertEq(vault.totalInvested(), investAmount, "totalInvested must not change");

        assertApproxEqRel(vault.totalAssets(), assets, 0.0015e18, "must not change total assets");

        _assertLtvs(0, 0, updatedAaveTargetLtv);
        _assertAllocations(0, 0, 1e18);
    }

    function testRevertsIfLtvForUnsupportedAdapterNot0() public {
        // the script must revert in case of an unsupported adapter
        vault.deposit{value: 10 ether}(address(this));
        uint256 id = morphoAdapter.id();
        hoax(MainnetAddresses.MULTISIG);
        vault.removeAdapter(id, true);

        script.updateMorphoTargetLtv(0.8e18);
        script.setMorphoInvestableAmountPercent(0);
        script.setCompoundV3InvestableAmountPercent(0.4e18);
        script.setAaveV3InvestableAmountPercent(0.6e18);

        vm.expectRevert(abi.encodePacked(RebalanceScWethV2.ScriptAdapterNotSupported.selector, id));
        script.run();
    }

    function testRevertsIfAllocationPercentForUnsupportedAdapterNot0() public {
        // the script must revert in case of an unsupported adapter
        vault.deposit{value: 10 ether}(address(this));
        uint256 id = morphoAdapter.id();
        hoax(MainnetAddresses.MULTISIG);
        vault.removeAdapter(id, true);

        script.updateMorphoTargetLtv(0);
        script.setMorphoInvestableAmountPercent(0.1e18);
        script.setCompoundV3InvestableAmountPercent(0.3e18);
        script.setAaveV3InvestableAmountPercent(0.6e18);

        vm.expectRevert(abi.encodePacked(RebalanceScWethV2.ScriptAdapterNotSupported.selector, id));
        script.run();
    }

    function testWorksIfLtvAndAllocationPercentForUnsupportedAdapterIs0() public {
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));
        uint256 investAmount = _investAmount();

        uint256 id = morphoAdapter.id();
        hoax(MainnetAddresses.MULTISIG);
        vault.removeAdapter(id, true);

        script.updateMorphoTargetLtv(0);
        script.setMorphoInvestableAmountPercent(0);
        script.setCompoundV3InvestableAmountPercent(0.4e18);
        script.setAaveV3InvestableAmountPercent(0.6e18);

        script.run();

        assertEq(vault.totalInvested(), investAmount, "totalInvested must not change");
        _assertAllocations(0, 0.4e18, 0.6e18);
        _assertLtvs(0, script.compoundV3TargetLtv(), script.aaveV3TargetLtv());
    }

    function testFloatResetsOnRebalance() public {
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));

        script.run();

        _simulate_stEthStakingInterest(365 days, 1.071e18);

        vault.withdraw(0.5 ether, address(this), address(this));

        uint256 assets = vault.totalAssets();

        assertLt(weth.balanceOf(address(vault)), vault.minimumFloatAmount(), "float not less than minimumFloat");

        script = new RebalanceScWethV2TestHarness(); // reset script state
        script.run();

        assertApproxEqRel(
            weth.balanceOf(address(vault)), vault.minimumFloatAmount(), 0.005e18, "float not reset after rebalance"
        );

        assertGe(weth.balanceOf(address(vault)), vault.minimumFloatAmount());

        assertApproxEqRel(vault.totalAssets(), assets, 0.001e18, "must not change total assets");
    }

    function testRevertsIfVaultDoesNotHaveEnoughAssetsForFloat() public {
        uint256 amount = 1.5 ether;
        vault.deposit{value: amount}(address(this));

        script.run();

        vault.withdraw(0.8 ether, address(this), address(this));

        vm.expectRevert(abi.encodePacked(RebalanceScWethV2.FloatRequiredIsMoreThanTotalInvested.selector));
        script.run();
    }

    function testWstEthFloatRebalance() public {
        uint256 amount = 1.5 ether;
        vault.deposit{value: amount}(address(this));

        script.run();

        uint256 simulatedWstEthDust = 1e18;

        // put some wstEthFloat in the vault
        hoax(0x0B925eD163218f6662a35e0f0371Ac234f9E9371);
        ERC20(C.WSTETH).transfer(address(vault), simulatedWstEthDust);

        vault.deposit{value: amount}(address(this));

        assertGe(ERC20(C.WSTETH).balanceOf(address(vault)), simulatedWstEthDust, "wsTETH dust transfer error");

        script = new RebalanceScWethV2TestHarness(); // reset script state
        script.run();

        assertLt(
            ERC20(C.WSTETH).balanceOf(address(vault)),
            simulatedWstEthDust.mulWadDown(0.0002e18),
            "wstETH dust not being rebalanced"
        );
    }

    //////////////////////////////////// INTERNAL METHODS ///////////////////////////////////////

    function _investAmount() internal view returns (uint256) {
        return weth.balanceOf(address(vault)) - vault.minimumFloatAmount();
    }

    function _assertLtvs(uint256 _morphoLtv, uint256 _compoundLtv, uint256 _aaveLtv) internal {
        assertApproxEqRel(script.getLtv(morphoAdapter), _morphoLtv, 0.005e18, "morpho ltv not correct");
        assertApproxEqRel(script.getLtv(compoundV3Adapter), _compoundLtv, 0.005e18, "compound ltv not correct");
        assertApproxEqRel(script.getLtv(aaveV3Adapter), _aaveLtv, 0.005e18, "aave ltv not correct");
    }

    function _assertAllocations(uint256 _morphoAllocation, uint256 _compoundAllocation, uint256 _aaveAllocation)
        internal
    {
        // assert allocations must not change

        if (_morphoAllocation > 0) {
            assertApproxEqRel(
                script.allocationPercent(morphoAdapter),
                _morphoAllocation,
                0.005e18,
                "morpho allocationPercent not correct"
            );
        }

        if (_compoundAllocation > 0) {
            assertApproxEqRel(
                script.allocationPercent(compoundV3Adapter),
                _compoundAllocation,
                0.005e18,
                "compound allocationPercent not correct"
            );
        }

        if (_aaveAllocation > 0) {
            assertApproxEqRel(
                script.allocationPercent(aaveV3Adapter), _aaveAllocation, 0.005e18, "aave allocationPercent not correct"
            );
        }
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

contract RebalanceScWethV2TestHarness is RebalanceScWethV2 {
    bytes testSwapData;

    function getSwapData(uint256, address, address) public view override returns (bytes memory swapData) {
        return testSwapData;
    }

    function setDemoSwapData(bytes memory _swapData) external {
        testSwapData = _swapData;
    }

    function updateMorphoTargetLtv(uint256 _ltv) external {
        morphoTargetLtv = _ltv;
    }

    function updateCompoundV3TargetLtv(uint256 _ltv) external {
        compoundV3TargetLtv = _ltv;
    }

    function updateAaveV3TargetLtv(uint256 _ltv) external {
        aaveV3TargetLtv = _ltv;
    }

    function setMorphoInvestableAmountPercent(uint256 _percent) external {
        morphoInvestableAmountPercent = _percent;
    }

    function setCompoundV3InvestableAmountPercent(uint256 _percent) external {
        compoundV3InvestableAmountPercent = _percent;
    }

    function setAaveV3InvestableAmountPercent(uint256 _percent) external {
        aaveV3InvestableAmountPercent = _percent;
    }
}

// test that the invest amount is updated correctly in all above tests
// specially in a test where new deposit is added before a (disinvest + invest) & (all disinvests)
