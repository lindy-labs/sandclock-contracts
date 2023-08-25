// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {scUSDCv2} from "../../src/steth/scUSDCv2.sol";
import {PriceConverter} from "../../src/steth/PriceConverter.sol";
import {AaveV2ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {ReallocateScUsdcV2} from "../../script/v2/actions/ReallocateScUsdcV2.s.sol";
import {MainnetAddresses} from "../../script/base/MainnetAddresses.sol";
import {Constants} from "../../src/lib/Constants.sol";

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
        vm.rollFork(17987643);

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

        uint256 morphoInitialCollateral = vault.getCollateral(morpho.id());
        uint256 morphoInitialDebt = vault.getDebt(morpho.id());
        uint256 aaveV2InitialCollateral = vault.getCollateral(aaveV2.id());
        uint256 aaveV2InitialDebt = vault.getDebt(aaveV2.id());

        uint256 morphoWithdrawAmount = morphoInitialCollateral / 2;
        uint256 morphoRepayAmount = morphoInitialDebt / 2;

        assertTrue(script.useMorpho(), "morpho not used");
        assertTrue(script.useAaveV2(), "aave v2 not used");
        script.setMorphoWithdrawAmount(morphoWithdrawAmount);
        script.setMorphoRepayAmount(morphoRepayAmount);
        script.setAaveV2SupplyAmount(morphoWithdrawAmount);
        script.setAavveV2BorrowAmount(morphoRepayAmount);

        script.run();

        assertApproxEqRel(
            vault.getCollateral(morpho.id()),
            morphoInitialCollateral - morphoWithdrawAmount,
            0.0001e18,
            "morpho collateral"
        );
        assertApproxEqRel(
            vault.getCollateral(aaveV2.id()),
            aaveV2InitialCollateral + morphoWithdrawAmount,
            0.0001e18,
            "aave v2 collateral"
        );
        assertApproxEqRel(vault.getDebt(morpho.id()), morphoInitialDebt - morphoRepayAmount, 0.0001e18, "morpho debt");
        assertApproxEqRel(vault.getDebt(aaveV2.id()), aaveV2InitialDebt + morphoRepayAmount, 0.0001e18, "aave v2 debt");
    }

    function test_run_moveWholePositionFromAaveV2ToMorpho() public {
        assertTrue(vault.totalDebt() > 0, "vault has no debt");
        assertTrue(vault.totalCollateral() > 0, "vault has no collateral");

        uint256 morphoInitialCollateral = vault.getCollateral(morpho.id());
        uint256 morphoInitialDebt = vault.getDebt(morpho.id());
        uint256 aaveV2InitialCollateral = vault.getCollateral(aaveV2.id());
        uint256 aaveV2InitialDebt = vault.getDebt(aaveV2.id());

        uint256 aaveV2WithdrawAmount = aaveV2InitialCollateral;
        uint256 aaveV2RepayAmount = aaveV2InitialDebt;

        assertTrue(script.useAaveV2(), "aave v2 not used");
        assertTrue(script.useMorpho(), "morpho not used");
        script.setAaveV2WithdrawAmount(aaveV2WithdrawAmount);
        script.setAaveV2RepayAmount(aaveV2RepayAmount);
        script.setMorphoSupplyAmount(aaveV2WithdrawAmount);
        script.setMorphoBorrowAmount(aaveV2RepayAmount);

        script.run();

        assertApproxEqRel(
            vault.getCollateral(morpho.id()),
            morphoInitialCollateral + aaveV2WithdrawAmount,
            0.0001e18,
            "morpho collateral"
        );
        assertApproxEqAbs(vault.getCollateral(aaveV2.id()), 0, 1, "aave v2 collateral");
        assertApproxEqRel(vault.getDebt(morpho.id()), morphoInitialDebt + aaveV2RepayAmount, 0.0001e18, "morpho debt");
        assertApproxEqAbs(vault.getDebt(aaveV2.id()), 0, 1, "aave v2 debt");
    }

    function test_run_moveHalfFromAaveV2AndMorphoToAaveV3() public {
        assertTrue(vault.totalDebt() > 0, "vault has no debt");
        assertTrue(vault.totalCollateral() > 0, "vault has no collateral");
        _addAaveV3Adapter();

        uint256 morphoInitialCollateral = vault.getCollateral(morpho.id());
        uint256 morphoInitialDebt = vault.getDebt(morpho.id());
        uint256 aaveV2InitialCollateral = vault.getCollateral(aaveV2.id());
        uint256 aaveV2InitialDebt = vault.getDebt(aaveV2.id());
        uint256 aaveV3InitialCollateral = vault.getCollateral(aaveV3.id());
        uint256 aaveV3InitialDebt = vault.getDebt(aaveV3.id());

        uint256 aaveV2WithdrawAmount = aaveV2InitialCollateral / 2;
        uint256 aaveV2RepayAmount = aaveV2InitialDebt / 2;
        uint256 morphoWithdrawAmount = morphoInitialCollateral / 2;
        uint256 morphoRepayAmount = morphoInitialDebt / 2;
        uint256 aaveV3SupplyAmount = aaveV2WithdrawAmount + morphoWithdrawAmount;
        uint256 aaveV3BorrowAmount = aaveV2RepayAmount + morphoRepayAmount;

        assertTrue(script.useAaveV2(), "aave v2 not used");
        assertTrue(script.useMorpho(), "morpho not used");
        assertTrue(script.useAaveV3(), "aave v3 not used");

        script.setAaveV2WithdrawAmount(aaveV2WithdrawAmount);
        script.setAaveV2RepayAmount(aaveV2RepayAmount);
        script.setMorphoWithdrawAmount(morphoWithdrawAmount);
        script.setMorphoRepayAmount(morphoRepayAmount);
        script.setAaveV3SupplyAmount(aaveV3SupplyAmount);
        script.setAaveV3BorrowAmount(aaveV3BorrowAmount);

        script.run();

        assertApproxEqRel(
            vault.getCollateral(morpho.id()),
            morphoInitialCollateral - morphoWithdrawAmount,
            0.0001e18,
            "morpho collateral"
        );
        assertApproxEqRel(
            vault.getCollateral(aaveV2.id()),
            aaveV2InitialCollateral - aaveV2WithdrawAmount,
            0.0001e18,
            "aave v2 collateral"
        );
        assertApproxEqRel(
            vault.getCollateral(aaveV3.id()),
            aaveV3InitialCollateral + aaveV2WithdrawAmount + morphoWithdrawAmount,
            0.0001e18,
            "aave v3 collateral"
        );

        assertApproxEqRel(vault.getDebt(morpho.id()), morphoInitialDebt - morphoRepayAmount, 0.0001e18, "morpho debt");
        assertApproxEqRel(vault.getDebt(aaveV2.id()), aaveV2InitialDebt - aaveV2RepayAmount, 0.0001e18, "aave v2 debt");
        assertApproxEqRel(
            vault.getDebt(aaveV3.id()),
            aaveV3InitialDebt + aaveV2RepayAmount + morphoRepayAmount,
            0.0001e18,
            "aave v3 debt"
        );
    }

    function test_run_failsIfWithdrawAndSupplyAmountsSumIsNot0() public {
        script.setUseAaveV3(true);
        _addAaveV3Adapter();

        script.setAaveV2WithdrawAmount(5e6);
        script.setMorphoWithdrawAmount(5e6);
        script.setAaveV3SupplyAmount(0);

        vm.expectRevert("total supply change != 0");
        script.run();
    }

    function test_run_failsIfRepayAndBorrowAmountsSumIsNot0() public {
        script.setUseAaveV3(true);
        _addAaveV3Adapter();

        script.setAaveV2WithdrawAmount(5e6);
        script.setMorphoWithdrawAmount(5e6);
        script.setAaveV3SupplyAmount(10e6);

        script.setMorphoRepayAmount(5e18);
        script.setAaveV2RepayAmount(10e18);
        script.setAaveV3BorrowAmount(10e18);

        vm.expectRevert("total debt change != 0");
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

        assertApproxEqAbs(vault.totalDebt(), borrowAmount, 2, "vault total debt");
        assertApproxEqAbs(vault.totalCollateral(), investableAmount, 2, "vault total collateral");
    }

    function _addAaveV3Adapter() internal {
        if (!vault.isSupported(aaveV3.id())) {
            vm.prank(Constants.MULTISIG);
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

    function setMorphoSupplyAmount(uint256 _amount) public {
        morphoSupplyAmount = _amount;
    }

    function setMorphoBorrowAmount(uint256 _amount) public {
        morphoBorrowAmount = _amount;
    }

    function setMorphoWithdrawAmount(uint256 _amount) public {
        morphoWithdrawAmount = _amount;
    }

    function setMorphoRepayAmount(uint256 _amount) public {
        morphoRepayAmount = _amount;
    }

    function setUseAaveV2(bool _isUsed) public {
        useAaveV2 = _isUsed;
    }

    function setAaveV2SupplyAmount(uint256 _amount) public {
        aaveV2SupplyAmount = _amount;
    }

    function setAavveV2BorrowAmount(uint256 _amount) public {
        aaveV2BorrowAmount = _amount;
    }

    function setAaveV2WithdrawAmount(uint256 _amount) public {
        aaveV2WithdrawAmount = _amount;
    }

    function setAaveV2RepayAmount(uint256 _amount) public {
        aaveV2RepayAmount = _amount;
    }

    function setUseAaveV3(bool _isUsed) public {
        useAaveV3 = _isUsed;
    }

    function setAaveV3SupplyAmount(uint256 _amount) public {
        aaveV3SupplyAmount = _amount;
    }

    function setAaveV3BorrowAmount(uint256 _amount) public {
        aaveV3BorrowAmount = _amount;
    }

    function setAaveV3RepayAmount(uint256 _amount) public {
        aaveV3RepayAmount = _amount;
    }

    function setAaveV3WithdrawAmount(uint256 _amount) public {
        aaveV3WithdrawAmount = _amount;
    }
}
