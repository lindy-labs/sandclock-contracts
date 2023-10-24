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
import {MainnetAddresses as MA} from "../../script/base/MainnetAddresses.sol";
import {RebalanceScWethV2} from "../../script/v2/keeper-actions/RebalanceScWethV2.s.sol";
import {ReallocateScWethV2} from "../../script/v2/keeper-actions/ReallocateScWethV2.s.sol";
import {scWETHv2} from "../../src/steth/scWETHv2.sol";
import {IAdapter} from "../../src/steth/IAdapter.sol";
import {Swapper} from "../../src/steth/Swapper.sol";
import {PriceConverter} from "../../src/steth/PriceConverter.sol";

contract ReallocateScWethV2Test is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    RebalanceScWethV2TestHarness rebalanceScWethV2;
    ReallocateScWethV2TestHarness script;
    scWETHv2 vault;
    WETH weth = WETH(payable(C.WETH));

    IAdapter morphoAdapter;
    IAdapter compoundV3Adapter;
    IAdapter aaveV3Adapter;

    // init percents as per rebalance script
    uint256 morphoInitPercent;
    uint256 aaveV3InitPercent;
    uint256 compoundInitPercent;

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18018649);

        scWETHv2 _vault = _redeployScWethV2();

        rebalanceScWethV2 = new RebalanceScWethV2TestHarness(_vault);

        script = new ReallocateScWethV2TestHarness(_vault);
        vault = script.vault();

        morphoAdapter = script.morphoAdapter();
        compoundV3Adapter = script.compoundV3Adapter();
        aaveV3Adapter = script.aaveV3Adapter();

        morphoInitPercent = rebalanceScWethV2.morphoInvestableAmountPercent();
        aaveV3InitPercent = rebalanceScWethV2.aaveV3InvestableAmountPercent();
        compoundInitPercent = rebalanceScWethV2.compoundV3InvestableAmountPercent();
    }

    function _redeployScWethV2() internal returns (scWETHv2 _vault) {
        _vault =
        new scWETHv2(C.MULTISIG, MA.KEEPER, WETH(payable(C.WETH)), Swapper(MA.SWAPPER), PriceConverter(MA.PRICE_CONVERTER));

        vm.startPrank(C.MULTISIG);
        _vault.addAdapter(IAdapter(MA.SCWETHV2_MORPHO_ADAPTER));
        _vault.addAdapter(IAdapter(MA.SCWETHV2_COMPOUND_ADAPTER));
        _vault.addAdapter(IAdapter(MA.SCWETHV2_AAVEV3_ADAPTER));
        vm.stopPrank();
    }

    function testMorphoIncreaseCompoundDecrease() public {
        _testAllocations(0.5e18, 0.5e18, 0);
    }

    function testAllInAave() public {
        _testAllocations(0, 0, 1e18);
    }

    function testAllInMorpho() public {
        _testAllocations(1e18, 0, 0);
    }

    function testAllInCompound() public {
        _testAllocations(0, 1e18, 0);
    }

    function testMorphoDecreaseOtherTwoIncrease() public {
        _testAllocations(0.1e18, 0.7e18, 0.2e18);
    }

    function testCompoundAaveIncrease() public {
        _testAllocations(0, 0.7e18, 0.3e18);
    }

    function testOnlyAaveIncrease() public {
        _testAllocations(0.1e18, 0.1e18, 0.8e18);
    }

    function _testAllocations(uint256 _morphoAllocation, uint256 _compoundV3Allocation, uint256 _aaveV3Allocation)
        internal
    {
        uint256 investAmount = _rebalance();

        // assert init Allocations
        _assertAllocations(morphoInitPercent, compoundInitPercent, aaveV3InitPercent);

        uint256 assets = vault.totalAssets();
        uint256 float = weth.balanceOf(address(vault));

        _setAllocations(_morphoAllocation, _compoundV3Allocation, _aaveV3Allocation);

        script.run();

        assertApproxEqRel(vault.totalAssets(), assets, 100, "total Assets changed");
        assertApproxEqRel(vault.totalInvested(), investAmount, 0.01e18, "investAmount changed");
        assertEq(weth.balanceOf(address(vault)), float, "float changed");

        _assertAllocations(_morphoAllocation, _compoundV3Allocation, _aaveV3Allocation);
    }

    function _setAllocations(uint256 _morphoAllocation, uint256 _compoundV3Allocation, uint256 _aaveV3Allocation)
        internal
    {
        script.setMorphoAllocation(_morphoAllocation);
        script.setCompoundAllocation(_compoundV3Allocation);
        script.setAaveV3Allocation(_aaveV3Allocation);
    }

    function _rebalance() internal returns (uint256 investAmount) {
        uint256 amount = 10 ether;
        vault.deposit{value: amount}(address(this));

        investAmount = weth.balanceOf(address(vault)) - vault.minimumFloatAmount();

        rebalanceScWethV2.run();
    }

    function _assertAllocations(uint256 _morphoAllocation, uint256 _compoundV3Allocation, uint256 _aaveV3Allocation)
        internal
    {
        assertApproxEqRel(script.allocationPercent(morphoAdapter), _morphoAllocation, 100);
        assertApproxEqRel(script.allocationPercent(compoundV3Adapter), _compoundV3Allocation, 100);
        assertApproxEqRel(script.allocationPercent(aaveV3Adapter), _aaveV3Allocation, 100);
    }
}

contract RebalanceScWethV2TestHarness is RebalanceScWethV2 {
    bytes testSwapData;

    constructor(scWETHv2 _vault) RebalanceScWethV2(_vault) {}

    function getSwapData(uint256, address, address) public view override returns (bytes memory swapData) {
        return testSwapData;
    }
}

contract ReallocateScWethV2TestHarness is ReallocateScWethV2 {
    constructor(scWETHv2 _vault) ReallocateScWethV2(_vault) {}

    function setMorphoAllocation(uint256 _val) public {
        expectedAllocationPercent[morphoAdapter] = _val;
    }

    function setAaveV3Allocation(uint256 _val) public {
        expectedAllocationPercent[aaveV3Adapter] = _val;
    }

    function setCompoundAllocation(uint256 _val) public {
        expectedAllocationPercent[compoundV3Adapter] = _val;
    }
}
