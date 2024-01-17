// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {Constants as C} from "../../../src/lib/Constants.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {scWETHv2} from "../../../src/steth/scWETHv2.sol";
import {PriceConverter} from "../../../src/steth/PriceConverter.sol";
import {AaveV2ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";

import {MainnetAddresses} from "../../../script/base/MainnetAddresses.sol";
import {FixtureConstants} from "../../../script/base/FixtureConstants.sol";
import {InProfitFixture} from "../../../script/v2/fixtures/InProfitFixture.s.sol";

contract InProfitFixtureTest is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    InProfitFixture script;

    ERC20 usdc = ERC20(C.USDC);
    WETH weth = WETH(payable(C.WETH));

    address alice = FixtureConstants.ALICE;
    address bob = FixtureConstants.BOB;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(18226426);

        script = new InProfitFixture();

        script.setDeployerPrivateKey(uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)); // junk key

        vm.deal(script.deployerAddress(), 1000 ether);
    }

    function test_run_deploysVautlsToExpectedAddresses() public {
        (scWETHv2 scWeth, scUSDCv2 scUsdc) = script.run();

        // assert deployment addresses
        assertEq(address(scWeth), 0xDC57724Ea354ec925BaFfCA0cCf8A1248a8E5CF1, "scWeth address");
        assertEq(address(scUsdc), 0x68d2Ecd85bDEbfFd075Fb6D87fFD829AD025DD5C, "scUsdc address");
    }

    function test_run_assignsKeeperRoleToDeployer() public {
        (scWETHv2 scWeth, scUSDCv2 scUsdc) = script.run();

        // both deployer and keeper have the keeper role for simplicity of running rebalance scripts
        assertTrue(scWeth.hasRole(scWeth.KEEPER_ROLE(), script.deployerAddress()), "deployer is not keeper");
        assertTrue(scWeth.hasRole(scWeth.KEEPER_ROLE(), FixtureConstants.KEEPER), "keeper is not keeper");
        assertTrue(scUsdc.hasRole(scUsdc.KEEPER_ROLE(), script.deployerAddress()), "deployer is not keeper");
        assertTrue(scUsdc.hasRole(scUsdc.KEEPER_ROLE(), FixtureConstants.KEEPER), "keeper is not keeper");
    }

    function test_run_rebalanceIsPerformedForBothVaults() public {
        (scWETHv2 scWeth, scUSDCv2 scUsdc) = script.run();

        // assert rebalance is performed on scUsdc
        assertTrue(scUsdc.totalDebt() > 0, "scUsdc 0 total debt");
        assertTrue(scUsdc.totalCollateral() > 0, "scUsdc 0 total collateral");
        assertTrue(scUsdc.wethInvested() > 0, "scUsdc 0 weth invested");

        // assert rebalance is performed on scWeth
        assertTrue(scWeth.totalDebt() > 0, "scWeth 0 total debt");
        assertTrue(scWeth.totalCollateral() > 0, "scWeth 0 total collateral");
        assertTrue(scWeth.totalInvested() > 0, "scWeth 0 invested");
    }

    function test_run_fundsAliceAndBobWithFreeAssetsAndDepositsInBothVaults() public {
        (scWETHv2 scWeth, scUSDCv2 scUsdc) = script.run();

        // assert free eth & usdc for bob and alice
        assertEq(usdc.balanceOf(alice), script.aliceFreeUsdc(), "alice free usdc");
        assertEq(usdc.balanceOf(bob), script.bobFreeUsdc(), "bob free usdc");
        assertEq(alice.balance, script.aliceFreeEth(), "alice free eth");
        assertEq(bob.balance, script.boblFreeEth(), "bob free eth");

        // assert alice & bob deposits to scUsdc
        uint256 aliceScUsdcShares = scUsdc.balanceOf(alice);
        assertTrue(aliceScUsdcShares > 0, "0 alice scUsdc shares");
        uint256 bobScUsdcShares = scUsdc.balanceOf(bob);
        assertTrue(bobScUsdcShares > 0, "0 bob scUsdc shares");

        // assert alice & bob deposits to scWeth
        uint256 aliceScWethShares = scWeth.balanceOf(alice);
        assertTrue(aliceScWethShares > 0, "0 alice scWeth shares");
        uint256 bobScWethShares = scWeth.balanceOf(bob);
        assertTrue(bobScWethShares > 0, "0 bob scWeth shares");
    }

    function test_run_simulatesProfitByAddingFundsToScWeth() public {
        (scWETHv2 scWeth, scUSDCv2 scUsdc) = script.run();

        assertTrue(scUsdc.getProfit() > 0, "scUsdc 0 profit");
        // assert the total assets greater than the initial deposits from bob and alice
        assertTrue(
            scUsdc.totalAssets() > script.aliceScUsdcDeposit() + script.bobScUsdcDeposit(),
            "scUsdc total assets < deposits"
        );
        assertTrue(
            scWeth.totalAssets() > script.aliceScWethDeposit() + script.bobScWethDeposit(),
            "scWeth total assets < deposits"
        );
    }
}
