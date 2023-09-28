// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";
import {IEulerMarkets, IEulerEToken, IEulerDToken} from "lib/euler-interfaces/contracts/IEuler.sol";

import {Constants as C} from "../src/lib/Constants.sol";
import {ILendingPool} from "../src/interfaces/aave-v2/ILendingPool.sol";
import {IProtocolDataProvider} from "../src/interfaces/aave-v2/IProtocolDataProvider.sol";
import {IAdapter} from "../src/steth/IAdapter.sol";
import {scUSDCv2} from "../src/steth/scUSDCv2.sol";
import {AaveV2ScUsdcAdapter} from "../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {AaveV3ScUsdcAdapter} from "../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {EulerScUsdcAdapter} from "../src/steth/scUsdcV2-adapters/EulerScUsdcAdapter.sol";
import {MorphoAaveV3ScUsdcAdapter} from "../src/steth/scUsdcV2-adapters/MorphoAaveV3ScUsdcAdapter.sol";

import {scWETH} from "../src/steth/scWETH.sol";
import {ISwapRouter} from "../src/interfaces/uniswap/ISwapRouter.sol";
import {AggregatorV3Interface} from "../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {PriceConverter} from "../src/steth/PriceConverter.sol";
import {Swapper} from "../src/steth/Swapper.sol";
import {IVault} from "../src/interfaces/balancer/IVault.sol";
import {ICurvePool} from "../src/interfaces/curve/ICurvePool.sol";
import {ILido} from "../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../src/interfaces/lido/IwstETH.sol";
import {IProtocolFeesCollector} from "../src/interfaces/balancer/IProtocolFeesCollector.sol";
import "../src/errors/scErrors.sol";
import {FaultyAdapter} from "./mocks/adapters/FaultyAdapter.sol";

contract ERC4626YieldWrapperTest is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);

    WETH weth;
    ERC20 usdc;

    scWETH wethVault;
    scUSDCv2 vault;
    AaveV3ScUsdcAdapter aaveV3;
    AaveV2ScUsdcAdapter aaveV2;
    EulerScUsdcAdapter euler;
    MorphoAaveV3ScUsdcAdapter morpho;
    Swapper swapper;
    PriceConverter priceConverter;

    ERC4626YieldWrapper wrapper;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(17529069);

        usdc = ERC20(C.USDC);
        weth = WETH(payable(C.WETH));
        aaveV3 = new AaveV3ScUsdcAdapter();
        aaveV2 = new AaveV2ScUsdcAdapter();
        euler = new EulerScUsdcAdapter();
        morpho = new MorphoAaveV3ScUsdcAdapter();

        _deployScWeth();
        _deployAndSetUpVault();
        wrapper = new ERC4626YieldWrapper(vault);
    }

    function test_claimYield_toSelf() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        wrapper.deposit(principal, address(this));

        assertEq(wrapper.yieldFor(address(this)), 0, "yield not 0 after deposit");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");

        // double the assets in the vault to simulate profit
        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        uint256 expectedYield = principal; // since yield is 100% of principal
        uint256 yield = wrapper.yieldFor(address(this));

        assertEq(yield, expectedYield, "yield not correct");

        uint256 claimedAmount = wrapper.claimYield();

        assertEq(claimedAmount, usdc.balanceOf(address(this)), "claimed amount not correct");
        assertEq(wrapper.yieldFor(address(this)), 0, "yield not 0 after claim");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");
    }

    function test_claimYield_toReceiver() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        wrapper.deposit(principal, alice);

        assertEq(wrapper.yieldFor(address(this)), 0, "yield not 0 after deposit");
        assertEq(wrapper.yieldFor(alice), 0, "receiver yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");

        // double the assets in the vault to simulate profit
        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        uint256 expectedYield = principal; // since yield is 100% of principal

        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(alice), expectedYield, "receiver yield 0");

        vm.prank(alice);
        wrapper.claimYield();

        assertEq(usdc.balanceOf(alice), expectedYield, "alice balance not correct");
        assertEq(wrapper.yieldFor(alice), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");
    }

    function test_claimYield_depositorWithdrawsBeforeYieldClaimed() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        wrapper.deposit(principal, alice);

        assertEq(wrapper.yieldFor(address(this)), 0, "yield not 0 after deposit");
        assertEq(wrapper.yieldFor(alice), 0, "receiver yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");

        // double the assets in the vault to simulate profit
        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        uint256 expectedYield = principal; // since yield is 100% of principal

        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(alice), expectedYield, "receiver yield 0");

        uint256 principalAmount = wrapper.principalFor(address(this));
        wrapper.withdraw(principalAmount);

        assertEq(usdc.balanceOf(address(this)), principal, "depositor balance not correct after withraw");
        assertEq(wrapper.principalFor(address(this)), 0, "principal != 0 after withdraw");
        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(alice), expectedYield, "receiver yield ");

        vm.prank(alice);
        wrapper.claimYield();

        assertEq(usdc.balanceOf(alice), expectedYield, "alice balance not correct");
        assertEq(wrapper.yieldFor(alice), 0, "depositor yield not 0");
    }

    function test_claimYield_depositorPartiallyWithdrawsBeforeYieldClaimed() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        wrapper.deposit(principal, alice);

        assertEq(wrapper.yieldFor(address(this)), 0, "yield not 0 after deposit");
        assertEq(wrapper.yieldFor(alice), 0, "receiver yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");

        // double the assets in the vault to simulate profit
        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        uint256 expectedYield = principal; // since yield is 100% of principal

        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(alice), expectedYield, "receiver yield 0");

        uint256 principalAmount = wrapper.principalFor(address(this));
        uint256 withdrawAmount = principalAmount / 2;
        wrapper.withdraw(withdrawAmount);

        assertEq(usdc.balanceOf(address(this)), withdrawAmount, "depositor balance after withraw");
        assertEq(wrapper.principalFor(address(this)), principalAmount - withdrawAmount, "principal after withdraw");
        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(alice), expectedYield, "receiver yield ");

        vm.prank(alice);
        wrapper.claimYield();

        assertEq(usdc.balanceOf(alice), expectedYield, "alice balance not correct");
        assertEq(wrapper.yieldFor(alice), 0, "depositor yield not 0");
    }

    /// internal helper functions ///

    function _deployScWeth() internal {
        scWETH.ConstructorParams memory scWethParams = scWETH.ConstructorParams({
            admin: address(this),
            keeper: keeper,
            targetLtv: 0.7e18,
            slippageTolerance: 0.99e18,
            aavePool: IPool(C.AAVE_V3_POOL),
            aaveAwstEth: IAToken(C.AAVE_V3_AWSTETH_TOKEN),
            aaveVarDWeth: ERC20(C.AAVE_V3_VAR_DEBT_WETH_TOKEN),
            curveEthStEthPool: ICurvePool(C.CURVE_ETH_STETH_POOL),
            stEth: ILido(C.STETH),
            wstEth: IwstETH(C.WSTETH),
            weth: WETH(payable(C.WETH)),
            stEthToEthPriceFeed: AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED),
            balancerVault: IVault(C.BALANCER_VAULT)
        });

        wethVault = new scWETH(scWethParams);
    }

    function _deployAndSetUpVault() internal {
        priceConverter = new PriceConverter(address(this));
        swapper = new Swapper();

        vault = new scUSDCv2(address(this), keeper, wethVault, priceConverter, swapper);

        vault.addAdapter(aaveV3);
        vault.addAdapter(aaveV2);

        // set vault eth balance to zero
        vm.deal(address(vault), 0);
        // set float percentage to 0 for most tests
        vault.setFloatPercentage(0);
        // assign keeper role to deployer
        vault.grantRole(vault.KEEPER_ROLE(), address(this));
    }
}

contract ERC4626YieldWrapper is ERC20 {
    using FixedPointMathLib for uint256;

    struct DepositReceipt {
        uint256 principal;
        address owner;
        uint256 pps;
        uint256 shares;
        address yieldReceiver;
    }

    function getReceipt(address _account) public view returns (DepositReceipt memory) {
        return depositReceitps[_account];
    }

    scUSDCv2 vault;
    mapping(address => DepositReceipt) public depositReceitps;
    mapping(address => address) public receiverToDepositor;

    constructor(scUSDCv2 _vault) ERC20("Yield Wrapper", "YIELD", 18) {
        vault = _vault;
        ERC20(C.USDC).approve(address(vault), type(uint256).max);
    }

    function deposit(uint256 _amount, address _yieldReceiver) public {
        ERC20(C.USDC).transferFrom(msg.sender, address(this), _amount);
        uint256 shares = vault.deposit(_amount, address(this));
        uint256 pps = currentPps();

        DepositReceipt memory receipt = DepositReceipt({
            principal: _amount,
            owner: msg.sender,
            pps: pps,
            shares: shares,
            yieldReceiver: _yieldReceiver
        });

        depositReceitps[msg.sender] = receipt;
        receiverToDepositor[_yieldReceiver] = msg.sender;

        _mint(_yieldReceiver, shares);
    }

    function withdraw(uint256 _principalAmount) public {
        DepositReceipt storage receipt = depositReceitps[msg.sender];
        uint256 shares = vault.withdraw(_principalAmount, address(this), address(this));
        ERC20(C.USDC).transfer(msg.sender, _principalAmount);
        receipt.principal -= _principalAmount;
        _burn(receipt.yieldReceiver, shares);
    }

    function yieldFor(address _account) public view returns (uint256 yield) {
        uint256 pps = currentPps();
        if (pps == 0) return 0;

        uint256 wrapperShares = this.balanceOf(_account);

        if (wrapperShares == 0) return 0;

        DepositReceipt memory receipt = depositReceitps[receiverToDepositor[_account]];

        yield = wrapperShares.mulWadDown(pps) - receipt.principal;
    }

    function principalFor(address _account) public view returns (uint256) {
        return depositReceitps[_account].principal;
    }

    function currentPps() public view returns (uint256) {
        if (vault.totalSupply() == 0) return 0;

        return vault.totalAssets().divWadDown(vault.totalSupply());
    }

    function claimYield() public returns (uint256) {
        uint256 pps = currentPps();
        uint256 yield = yieldFor(msg.sender);
        DepositReceipt storage receipt = depositReceitps[receiverToDepositor[msg.sender]];

        uint256 shares = vault.withdraw(yield, address(this), address(this));
        receipt.pps = pps;

        _burn(msg.sender, shares);
        ERC20(C.USDC).transfer(msg.sender, yield);

        return yield;
    }
}
