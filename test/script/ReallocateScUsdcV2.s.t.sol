// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {scUSDCv2} from "../../src/steth/scUSDCv2.sol";
import {PriceConverter} from "../../src/steth/PriceConverter.sol";
import {IAdapter} from "../../src/steth/IAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {ReallocateScUsdcV2} from "../../script/v2/keeper-actions/ReallocateScUsdcV2.s.sol";
import {MainnetAddresses} from "../../script/base/MainnetAddresses.sol";

contract ReallocateScUsdcV2Test is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    scUSDCv2 vault;
    AaveV3ScUsdcAdapter aaveV3;
    AaveV2ScUsdcAdapter aaveV2;
    MorphoAaveV3ScUsdcAdapter morpho;
    PriceConverter priceConverter;
    ReallocateScUsdcV2TestHarness script;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18488739);

        script = new ReallocateScUsdcV2TestHarness();

        vault = scUSDCv2(MainnetAddresses.SCUSDCV2);
        priceConverter = vault.priceConverter();
        morpho = script.morphoAdapter();
        aaveV2 = script.aaveV2Adapter();
        aaveV3 = script.aaveV3Adapter();

        _initialRebalance();
    }

    function test_run_moveHalfOfThePositionFromMorphoToAaveV2() public {
        assertTrue(vault.totalDebt() > 0, "vault has no debt");
        assertTrue(vault.totalCollateral() > 0, "vault has no collateral");

        assertEq(_getAllocationPercent(morpho), 0.5e18, "morpho allocation percent");
        assertEq(_getAllocationPercent(aaveV2), 0.5e18, "aave v2 allocation percent");

        uint256 morphoInitialCollateral = vault.getCollateral(morpho.id());
        uint256 morphoInitialDebt = vault.getDebt(morpho.id());
        uint256 aaveV2InitialCollateral = vault.getCollateral(aaveV2.id());
        uint256 aaveV2InitialDebt = vault.getDebt(aaveV2.id());

        assertTrue(script.useMorpho(), "morpho not used");
        assertTrue(script.useAaveV2(), "aave v2 not used");

        uint256 morphoAllocationPercent = 0.25e18;
        uint256 aaveV2AllocationPercent = 0.75e18;

        uint256 expectedMorphoWithdrawAmount = morphoInitialCollateral / 2;
        uint256 expectedMorphoRepayAmount = morphoInitialDebt / 2;

        script.setMorphoAllocationPercent(morphoAllocationPercent);
        script.setAaveV2AllocationPercent(aaveV2AllocationPercent);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 wethInvestedBefore = vault.wethInvested();

        script.run();

        assertApproxEqRel(
            vault.getCollateral(morpho.id()),
            morphoInitialCollateral - expectedMorphoWithdrawAmount,
            0.0001e18,
            "morpho collateral"
        );
        assertApproxEqRel(
            vault.getCollateral(aaveV2.id()),
            aaveV2InitialCollateral + expectedMorphoWithdrawAmount,
            0.0001e18,
            "aave v2 collateral"
        );
        assertApproxEqRel(
            vault.getDebt(morpho.id()), morphoInitialDebt - expectedMorphoRepayAmount, 0.0001e18, "morpho debt"
        );
        assertApproxEqRel(
            vault.getDebt(aaveV2.id()), aaveV2InitialDebt + expectedMorphoRepayAmount, 0.0001e18, "aave v2 debt"
        );
        assertApproxEqRel(
            _getAllocationPercent(morpho), morphoAllocationPercent, 0.0001e18, "morpho allocation percent"
        );
        assertApproxEqRel(
            _getAllocationPercent(aaveV2), aaveV2AllocationPercent, 0.0001e18, "aave v2 allocation percent"
        );
        assertApproxEqRel(vault.totalAssets(), totalAssetsBefore, 0.0001e18, "total assets");
        assertApproxEqRel(vault.wethInvested(), wethInvestedBefore, 0.0001e18, "weth invested");
    }

    function test_run_moveWholePositionFromAaveV2ToMorpho() public {
        assertTrue(vault.totalDebt() > 0, "vault has no debt");
        assertTrue(vault.totalCollateral() > 0, "vault has no collateral");

        uint256 morphoInitialCollateral = vault.getCollateral(morpho.id());
        uint256 morphoInitialDebt = vault.getDebt(morpho.id());
        uint256 aaveV2InitialCollateral = vault.getCollateral(aaveV2.id());
        uint256 aaveV2InitialDebt = vault.getDebt(aaveV2.id());

        uint256 expectedAaveV2WithdrawAmount = aaveV2InitialCollateral;
        uint256 expectedAaveV2RepayAmount = aaveV2InitialDebt;

        assertTrue(script.useAaveV2(), "aave v2 not used");
        assertTrue(script.useMorpho(), "morpho not used");

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 wethInvestedBefore = vault.wethInvested();

        uint256 morphoAllocationPercent = 1e18;
        uint256 aaveV2AllocationPercent = 0;

        script.setMorphoAllocationPercent(morphoAllocationPercent);
        script.setAaveV2AllocationPercent(aaveV2AllocationPercent);

        script.run();

        assertApproxEqRel(
            vault.getCollateral(morpho.id()),
            morphoInitialCollateral + expectedAaveV2WithdrawAmount,
            0.0001e18,
            "morpho collateral"
        );
        assertApproxEqAbs(vault.getCollateral(aaveV2.id()), 0, 1, "aave v2 collateral");
        assertApproxEqRel(
            vault.getDebt(morpho.id()), morphoInitialDebt + expectedAaveV2RepayAmount, 0.0001e18, "morpho debt"
        );
        assertApproxEqAbs(vault.getDebt(aaveV2.id()), 0, 1, "aave v2 debt");
        assertEq(_getAllocationPercent(morpho), morphoAllocationPercent, "morpho allocation percent");
        assertEq(_getAllocationPercent(aaveV2), aaveV2AllocationPercent, "aave v2 allocation percent");
        assertApproxEqAbs(vault.totalAssets(), totalAssetsBefore, 1, "total assets");
        assertEq(vault.wethInvested(), wethInvestedBefore, "weth invested");
    }

    function test_run_moveHalfFromAaveV2AndMorphoToAaveV3() public {
        assertTrue(vault.totalDebt() > 0, "vault has no debt");
        assertTrue(vault.totalCollateral() > 0, "vault has no collateral");
        _addAaveV3Adapter();
        assertEq(vault.getCollateral(aaveV3.id()), 0, "aave v3 collateral");
        assertEq(vault.getDebt(aaveV3.id()), 0, "aave v3 debt");

        uint256 morphoInitialCollateral = vault.getCollateral(morpho.id());
        uint256 morphoInitialDebt = vault.getDebt(morpho.id());
        uint256 aaveV2InitialCollateral = vault.getCollateral(aaveV2.id());
        uint256 aaveV2InitialDebt = vault.getDebt(aaveV2.id());

        uint256 expectedAaveV2WithdrawAmount = aaveV2InitialCollateral / 2;
        uint256 expectedAaveV2RepayAmount = aaveV2InitialDebt / 2;
        uint256 expectedMorphoWithdrawAmount = morphoInitialCollateral / 2;
        uint256 expectedMorphoRepayAmount = morphoInitialDebt / 2;

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 wethInvestedBefore = vault.wethInvested();

        script.setUseAaveV3(true);
        assertTrue(script.useAaveV2(), "aave v2 not used");
        assertTrue(script.useMorpho(), "morpho not used");
        assertTrue(script.useAaveV3(), "aave v3 not used");

        assertEq(_getAllocationPercent(morpho), 0.5e18, "morpho allocation percent");
        assertEq(_getAllocationPercent(aaveV2), 0.5e18, "aave v2 allocation percent");
        assertEq(_getAllocationPercent(aaveV3), 0, "aave v3 allocation percent");

        uint256 morphoAllocationPercent = 0.25e18;
        uint256 aaveV2AllocationPercent = 0.25e18;
        uint256 aaveV3AllocationPercent = 0.5e18;

        script.setMorphoAllocationPercent(morphoAllocationPercent);
        script.setAaveV2AllocationPercent(aaveV2AllocationPercent);
        script.setAaveV3AllocationPercent(aaveV3AllocationPercent);

        script.run();

        assertApproxEqRel(
            vault.getCollateral(morpho.id()),
            morphoInitialCollateral - expectedMorphoWithdrawAmount,
            0.0001e18,
            "morpho collateral"
        );
        assertApproxEqRel(
            vault.getCollateral(aaveV2.id()),
            aaveV2InitialCollateral - expectedAaveV2WithdrawAmount,
            0.0001e18,
            "aave v2 collateral"
        );
        assertApproxEqRel(
            vault.getCollateral(aaveV3.id()),
            expectedAaveV2WithdrawAmount + expectedMorphoWithdrawAmount,
            0.0001e18,
            "aave v3 collateral"
        );

        assertApproxEqRel(
            vault.getDebt(morpho.id()), morphoInitialDebt - expectedMorphoRepayAmount, 0.0001e18, "morpho debt"
        );
        assertApproxEqRel(
            vault.getDebt(aaveV2.id()), aaveV2InitialDebt - expectedAaveV2RepayAmount, 0.0001e18, "aave v2 debt"
        );
        assertApproxEqRel(
            vault.getDebt(aaveV3.id()), expectedAaveV2RepayAmount + expectedMorphoRepayAmount, 0.0001e18, "aave v3 debt"
        );

        assertApproxEqRel(
            _getAllocationPercent(morpho), morphoAllocationPercent, 0.0001e18, "morpho allocation percent"
        );
        assertApproxEqRel(
            _getAllocationPercent(aaveV2), aaveV2AllocationPercent, 0.0001e18, "aave v2 allocation percent"
        );
        assertApproxEqRel(
            _getAllocationPercent(aaveV3), aaveV3AllocationPercent, 0.0001e18, "aave v3 allocation percent"
        );

        assertApproxEqAbs(vault.totalAssets(), totalAssetsBefore, 1, "total assets");
        assertApproxEqAbs(vault.wethInvested(), wethInvestedBefore, 1, "weth invested");
    }

    function test_run_failsIfAllocationPercentSumIsNot100() public {
        script.setUseAaveV3(true);
        _addAaveV3Adapter();

        script.setAaveV3AllocationPercent(0.5e18);
        script.setAaveV2AllocationPercent(0.4e18);

        vm.expectRevert("total allocation percent not 100%");
        script.run();
    }

    function _initialRebalance() internal {
        // do the initial rebalance since at the current fork block the vault has no debt and no collateral positions
        // if this was to change than initial rebalance wouldn't be neccecary
        require(vault.totalDebt() == 0, "vault has debt");
        require(vault.totalCollateral() == 0, "vault has collateral");

        uint256 investableAmount = vault.totalAssets().mulWadDown(vault.floatPercentage());
        uint256 borrowAmount = priceConverter.usdcToEth(investableAmount.mulWadDown(0.7e18)); // 0.7 target ltv

        bytes[] memory callData = new bytes[](4);
        callData[0] = abi.encodeWithSelector(vault.supply.selector, morpho.id(), investableAmount / 2);
        callData[1] = abi.encodeWithSelector(vault.borrow.selector, morpho.id(), borrowAmount / 2);
        callData[2] = abi.encodeWithSelector(vault.supply.selector, aaveV2.id(), investableAmount / 2);
        callData[3] = abi.encodeWithSelector(vault.borrow.selector, aaveV2.id(), borrowAmount / 2);

        vm.startPrank(MainnetAddresses.KEEPER);

        vault.rebalance(callData);

        vm.stopPrank();

        assertApproxEqRel(vault.totalDebt(), borrowAmount, 0.0001e18, "vault total debt");
        assertApproxEqRel(vault.totalCollateral(), investableAmount, 0.0001e18, "vault total collateral");
    }

    function _getAllocationPercent(IAdapter _adapter) internal view returns (uint256) {
        return _adapter.getCollateral(address(vault)).divWadDown(vault.totalCollateral());
    }

    function _addAaveV3Adapter() internal {
        if (!vault.isSupported(aaveV3.id())) {
            vm.prank(MainnetAddresses.MULTISIG);
            vault.addAdapter(aaveV3);
            assertTrue(vault.isSupported(aaveV3.id()), "aave v3 not supported");
            script.setUseAaveV3(true);
        }
    }
}

contract ReallocateScUsdcV2TestHarness is ReallocateScUsdcV2 {
    function setUseMorpho(bool _isUsed) public {
        useMorpho = _isUsed;
    }

    function setMorphoAllocationPercent(uint256 _percent) public {
        morphoAllocationPercent = _percent;
    }

    function setUseAaveV2(bool _isUsed) public {
        useAaveV2 = _isUsed;
    }

    function setAaveV2AllocationPercent(uint256 _percent) public {
        aaveV2AllocationPercent = _percent;
    }

    function setUseAaveV3(bool _isUsed) public {
        useAaveV3 = _isUsed;
    }

    function setAaveV3AllocationPercent(uint256 _percent) public {
        aaveV3AllocationPercent = _percent;
    }
}
