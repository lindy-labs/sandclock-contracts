// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

import {MainnetAddresses} from "script/base/MainnetAddresses.sol";
import {scWETHv2Keeper} from "src/steth/scWETHv2Keeper.sol";
import {scWETHv2} from "src/steth/scWETHv2.sol";
import {InvestScWETHv2Keeper} from "script/v2/keeper-actions/InvestScWETHv2Keeper.s.sol";
import {IScETHPriceConverter} from "src/steth/priceConverter/IScETHPriceConverter.sol";

contract InvestScWETHv2KeeperTest is Test {
    using FixedPointMathLib for uint256;

    scWETHv2Keeper keeper;
    scWETHv2 vault;
    IERC20 weth;
    InvestScWETHv2Keeper script;

    // generated operator address and key
    address operator = 0x65015a7061FEe25268827416Ec7f5717227a43Ff;
    uint256 operatorKey = 0xa641a145d08e1008aa2dd3aea8a69b747ce369537d491e8226f4e92673c31ba6;

    function _setUp(uint256 _forkAtBlock) public {
        // set the operator private key env variable for the script to read
        vm.setEnv("OPERATOR_PRIVATE_KEY", Strings.toHexString(operatorKey));

        uint256 mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(_forkAtBlock);

        vault = scWETHv2(payable(MainnetAddresses.SCWETHV2));
        weth = IERC20(address(vault.asset()));
        // deploy the scWETHv2Keeper contract and set env variable for the script to read
        keeper = new scWETHv2Keeper(vault, address(this), operator);
        vm.setEnv("SCWETHV2_KEEPER", Strings.toHexString(address(keeper)));

        // grant keeper role to the keeper contract
        vm.startPrank(MainnetAddresses.MULTISIG);
        vault.grantRole(vault.KEEPER_ROLE(), address(keeper));
        vm.stopPrank();

        script = new InvestScWETHv2Keeper();
    }

    function test_run_successfullyInvestsAvaiableAssets() public {
        _setUp(20068274);

        // assert initial vault state
        uint256 investableAmount = weth.balanceOf(address(vault)) - vault.minimumFloatAmount();
        assertTrue(investableAmount > 0, "investableAmount should be greater than 0");
        uint256 initialCollateralInWeth =
            IScETHPriceConverter(address(vault.priceConverter())).wstEthToEth(vault.totalCollateral());
        uint256 targetLtv = 0.9e18;
        assertEq(script.aaveV3TargetLtv(), targetLtv, "targetLtv should be 0.9e18");

        script.run();

        // assert final vault state
        assertApproxEqAbs(
            weth.balanceOf(address(vault)) - vault.minimumFloatAmount(), 0, 1, "investableAmount should be 0"
        );
        uint256 finalCollateralInWeth =
            IScETHPriceConverter(address(vault.priceConverter())).wstEthToEth(vault.totalCollateral());
        assertApproxEqRel(
            finalCollateralInWeth - initialCollateralInWeth,
            investableAmount.divWadUp(1e18 - targetLtv),
            0.001e18,
            "collateral not increased as expected"
        );
        assertApproxEqAbs(
            vault.totalDebt().divWadDown(finalCollateralInWeth), targetLtv, 0.001e18, "target ltv not reached"
        );
    }
}
