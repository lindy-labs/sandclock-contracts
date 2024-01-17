// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {Script} from "forge-std/Script.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";

import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

import {RebalanceScUsdcV2} from "../keeper-actions/RebalanceScUsdcV2.s.sol";
import {RebalanceScWethV2} from "../keeper-actions/RebalanceScWethV2.s.sol";
import {CREATE3Script} from "../../base/CREATE3Script.sol";
import {MainnetAddresses} from "../../base/MainnetAddresses.sol";
import {FixtureConstants} from "../../base/FixtureConstants.sol";

import {Constants as C} from "../../../src/lib/Constants.sol";
import {Swapper} from "../../../src/steth/Swapper.sol";
import {PriceConverter} from "../../../src/steth/PriceConverter.sol";
import {scWETHv2} from "../../../src/steth/scWETHv2.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {MorphoAaveV3ScWethAdapter} from "../../../src/steth/scWethV2-adapters/MorphoAaveV3ScWethAdapter.sol";
import {CompoundV3ScWethAdapter} from "../../../src/steth/scWethV2-adapters/CompoundV3ScWethAdapter.sol";
import {AaveV3ScWethAdapter} from "../../../src/steth/scWethV2-adapters/AaveV3ScWethAdapter.sol";
import {AaveV2ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../../../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";
import {ISwapRouter} from "../../../src/interfaces/uniswap/ISwapRouter.sol";

/**
 * This script sets up the "in profit" scenario for both scUsdcV2 and scWethV2 vaults on a forked node and does the following:
 * 1. deploys scWethV2 and scUsdcV2
 * 2. funds alice and bob with eth and usdc (from deployer account)
 * 3. deposits to scWethV2 and scUsdcV2 for alice and bob
 * 4. rebalances scWethV2 and scUsdcV2
 * 5. adds profit to scWethV2
 */
contract InProfitFixture is CREATE3Script, Test {
    using FixedPointMathLib for uint256;
    using Address for address;
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;

    /*//////////////////////////////////////////////////////////////
                          SCRIPT PARAMETERS
    //////////////////////////////////////////////////////////////*/

    // @dev make sure that the deployer has more ETH than the "sum" of all assets below
    uint256 public aliceFreeEth = 100 ether;
    uint256 public aliceScWethDeposit = 100 ether;
    uint256 public aliceFreeUsdc = 50_000e6;
    uint256 public aliceScUsdcDeposit = 100_000e6;

    uint256 public boblFreeEth = 100 ether;
    uint256 public bobScWethDeposit = 200 ether;
    uint256 public bobFreeUsdc = 50_000e6;
    uint256 public bobScUsdcDeposit = 200_000e6;

    uint256 public scWethProfitPercentage = 0.2e18;

    /*//////////////////////////////////////////////////////////////*/

    scWETHv2 scWethV2;
    scUSDCv2 scUsdcV2;

    address alice = FixtureConstants.ALICE;
    address bob = FixtureConstants.BOB;

    WETH weth = WETH(payable(C.WETH));
    ERC20 usdc = ERC20(C.USDC);

    RebalanceScUsdcV2 rebalanceScUsdcScript = new RebalanceScUsdcV2();
    RebalanceScWethV2 rebalanceScWethScript = new RebalanceScWethV2();

    uint256 deployerPrivateKey = uint256(vm.envOr("PRIVATE_KEY", bytes32(0x0)));
    address public deployerAddress;

    function run() external returns (scWETHv2 scWeth, scUSDCv2 scUsdc) {
        require(deployerPrivateKey != 0, "invalid PRIVATE_KEY env variable");

        deployerAddress = vm.addr(deployerPrivateKey);

        (scWeth, scUsdc) = _deployVaults();

        _makeRichAliceAndBob();

        // rebalance scUsdc
        rebalanceScUsdcScript.setKeeperPrivateKey(deployerPrivateKey);
        rebalanceScUsdcScript.setVault(scUsdcV2);
        rebalanceScUsdcScript.run();

        // rebalance scWeth
        rebalanceScWethScript.setKeeperPrivateKey(deployerPrivateKey);
        rebalanceScWethScript.setVault(scWethV2);
        rebalanceScWethScript.run();

        _addScWethProfit();
    }

    function _deployVaults() internal returns (scWETHv2 scWeth, scUSDCv2 scUsdc) {
        vm.startBroadcast(deployerPrivateKey);

        Swapper swapper = Swapper(MainnetAddresses.SWAPPER);
        PriceConverter priceConverter = PriceConverter(MainnetAddresses.PRICE_CONVERTER);

        MorphoAaveV3ScWethAdapter morphoWeth = MorphoAaveV3ScWethAdapter(MainnetAddresses.SCWETHV2_MORPHO_ADAPTER);
        CompoundV3ScWethAdapter compoundV3Weth = CompoundV3ScWethAdapter(MainnetAddresses.SCWETHV2_COMPOUND_ADAPTER);
        AaveV3ScWethAdapter aaveV3Weth = AaveV3ScWethAdapter(MainnetAddresses.SCWETHV2_AAVEV3_ADAPTER);

        scWethV2 = new scWETHv2(deployerAddress, FixtureConstants.KEEPER, weth, swapper, priceConverter);
        // grant keeper role to deployer for simplicity
        scWethV2.grantRole(scWethV2.KEEPER_ROLE(), deployerAddress);
        scWethV2.addAdapter(morphoWeth);
        scWethV2.addAdapter(compoundV3Weth);
        scWethV2.addAdapter(aaveV3Weth);

        scUsdcV2 = new scUSDCv2(deployerAddress, FixtureConstants.KEEPER, scWethV2, priceConverter, swapper);
        // grant keeper role to deployer for simplicity
        scUsdcV2.grantRole(scUsdcV2.KEEPER_ROLE(), deployerAddress);
        AaveV2ScUsdcAdapter aaveV2Usdc = AaveV2ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV2_ADAPTER);
        AaveV3ScUsdcAdapter aaveV3Usdc = AaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_AAVEV3_ADAPTER);
        MorphoAaveV3ScUsdcAdapter morphoUsdc = MorphoAaveV3ScUsdcAdapter(MainnetAddresses.SCUSDCV2_MORPHO_ADAPTER);

        scUsdcV2.addAdapter(aaveV2Usdc);
        scUsdcV2.addAdapter(aaveV3Usdc);
        scUsdcV2.addAdapter(morphoUsdc);

        vm.stopBroadcast();

        return (scWethV2, scUsdcV2);
    }

    function _makeRichAliceAndBob() internal {
        vm.startBroadcast(deployerPrivateKey);

        // send eth to alice and bob
        payable(alice).transfer(100 ether);
        payable(bob).transfer(100 ether);

        PriceConverter priceConverter = PriceConverter(MainnetAddresses.PRICE_CONVERTER);
        uint256 usdcNeeded = aliceScUsdcDeposit + aliceFreeUsdc + bobScUsdcDeposit + bobFreeUsdc;
        uint256 wethNeededForSwap = priceConverter.usdcToEth(usdcNeeded).mulWadUp(1.1e18);

        // swap some weth for usdc
        weth.deposit{value: wethNeededForSwap + aliceScWethDeposit + bobScWethDeposit}();
        _exactWethToUsdcOutputSwap(usdcNeeded);

        // send free usdc to alice and bob
        usdc.safeTransfer(alice, aliceFreeUsdc);
        usdc.safeTransfer(bob, bobFreeUsdc);

        // deposit to scUsdc for alice and bob
        usdc.approve(address(scUsdcV2), type(uint256).max);
        scUsdcV2.deposit(aliceScUsdcDeposit, alice);
        scUsdcV2.deposit(bobScUsdcDeposit, bob);

        // deposit to scWeth for alice and bob
        weth.approve(address(scWethV2), type(uint256).max);
        scWethV2.deposit(aliceScWethDeposit, alice);
        scWethV2.deposit(bobScWethDeposit, bob);

        vm.stopBroadcast();
    }

    function _addScWethProfit() internal {
        vm.startBroadcast(deployerPrivateKey);

        uint256 scWethProfit = scWethV2.totalAssets().mulWadUp(scWethProfitPercentage);
        weth.deposit{value: scWethProfit}();
        weth.transfer(address(scWethV2), scWethProfit);

        vm.stopBroadcast();
    }

    function _exactWethToUsdcOutputSwap(uint256 _usdcAmountOut) internal returns (uint256) {
        ISwapRouter swapRouter = ISwapRouter(C.UNISWAP_V3_SWAP_ROUTER);

        ISwapRouter.ExactOutputSingleParams memory params = ISwapRouter.ExactOutputSingleParams({
            tokenIn: address(weth),
            tokenOut: address(usdc),
            fee: 500,
            recipient: deployerAddress,
            deadline: block.timestamp + 1 hours,
            amountOut: _usdcAmountOut,
            amountInMaximum: type(uint256).max,
            sqrtPriceLimitX96: 0
        });

        weth.safeApprove(address(swapRouter), type(uint256).max);

        return swapRouter.exactOutputSingle(params);
    }

    function setDeployerPrivateKey(uint256 _privateKey) public {
        deployerPrivateKey = _privateKey;
        deployerAddress = vm.addr(deployerPrivateKey);
    }
}
