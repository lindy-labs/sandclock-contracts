// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";

import {Constants as C} from "../src/lib/Constants.sol";
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

contract ERC4626YieldWrapperTest is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);
    address constant bob = address(0x07);
    address constant carol = address(0x08);

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

        _deployScWeth();
        _deployAndSetUpVault();
        wrapper = new ERC4626YieldWrapper(vault);
    }

    function test_claimYield_toSelf() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        ERC4626YieldWrapper.Claimer[] memory yieldClaimers = new ERC4626YieldWrapper.Claimer[](1);
        yieldClaimers[0] = ERC4626YieldWrapper.Claimer({account: address(this), percent: 1e18});
        wrapper.deposit(principal, yieldClaimers);

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

        ERC4626YieldWrapper.Claimer[] memory yieldClaimers = new ERC4626YieldWrapper.Claimer[](1);
        yieldClaimers[0] = ERC4626YieldWrapper.Claimer({account: alice, percent: 1e18});
        wrapper.deposit(principal, yieldClaimers);

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

    function test_claimYield_receiverCanClaimMoreThanOnce() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        ERC4626YieldWrapper.Claimer[] memory yieldClaimers = new ERC4626YieldWrapper.Claimer[](1);
        yieldClaimers[0] = ERC4626YieldWrapper.Claimer({account: alice, percent: 1e18});
        wrapper.deposit(principal, yieldClaimers);

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

        // double the assets in the vault to simulate profit
        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        expectedYield = principal; // since yield is 100% of principal

        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(alice), expectedYield, "receiver yield 0");

        vm.prank(alice);
        wrapper.claimYield();

        assertEq(usdc.balanceOf(alice), expectedYield * 2, "alice balance not correct");
        assertEq(wrapper.yieldFor(alice), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");
    }

    function test_claimYield_receiverTransfersSharesToAnotherAccount() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        ERC4626YieldWrapper.Claimer[] memory yieldClaimers = new ERC4626YieldWrapper.Claimer[](1);
        yieldClaimers[0] = ERC4626YieldWrapper.Claimer({account: alice, percent: 1e18});
        uint256 shares = wrapper.deposit(principal, yieldClaimers);

        assertEq(wrapper.balanceOf(alice), shares, "alice shares");
        assertEq(wrapper.yieldFor(alice), 0, "receiver yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");

        // double the assets in the vault to simulate profit
        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        uint256 expectedYield = principal; // since yield is 100% of principal
        vm.prank(alice);
        wrapper.transfer(bob, shares);

        assertEq(wrapper.balanceOf(alice), 0, "alice shares");
        assertEq(wrapper.balanceOf(bob), shares, "bob shares");

        assertEq(wrapper.yieldFor(alice), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(bob), expectedYield, "receiver yield 0");

        vm.prank(bob);
        wrapper.claimYield();

        assertEq(usdc.balanceOf(bob), expectedYield, "bob balance not correct");
        assertEq(wrapper.yieldFor(alice), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(bob), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");
    }

    function test_transferFrom_() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        ERC4626YieldWrapper.Claimer[] memory yieldClaimers = new ERC4626YieldWrapper.Claimer[](1);
        yieldClaimers[0] = ERC4626YieldWrapper.Claimer({account: alice, percent: 1e18});
        uint256 shares = wrapper.deposit(principal, yieldClaimers);

        assertEq(wrapper.balanceOf(alice), shares, "alice shares");
        assertEq(wrapper.yieldFor(alice), 0, "receiver yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");

        // double the assets in the vault to simulate profit
        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        uint256 expectedYield = principal; // since yield is 100% of principal
        vm.prank(alice);
        wrapper.approve(bob, shares);

        vm.prank(bob);
        wrapper.transferFrom(alice, bob, shares);

        assertEq(wrapper.balanceOf(alice), 0, "alice shares");
        assertEq(wrapper.balanceOf(bob), shares, "bob shares");

        assertEq(wrapper.yieldFor(alice), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(bob), expectedYield, "receiver yield 0");

        vm.prank(bob);
        wrapper.claimYield();

        assertEq(usdc.balanceOf(bob), expectedYield, "bob balance not correct");
        assertEq(wrapper.yieldFor(alice), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(bob), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");
    }

    function test_claimYield_depositorWithdrawsBeforeYieldClaimed() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        ERC4626YieldWrapper.Claimer[] memory yieldClaimers = new ERC4626YieldWrapper.Claimer[](1);
        yieldClaimers[0] = ERC4626YieldWrapper.Claimer({account: alice, percent: 1e18});
        wrapper.deposit(principal, yieldClaimers);

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
        assertEq(wrapper.yieldFor(alice), 0, "alice yield not 0");
    }

    function test_claimYield_depositorPartiallyWithdrawsBeforeYieldClaimed() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        ERC4626YieldWrapper.Claimer[] memory yieldClaimers = new ERC4626YieldWrapper.Claimer[](1);
        yieldClaimers[0] = ERC4626YieldWrapper.Claimer({account: alice, percent: 1e18});
        wrapper.deposit(principal, yieldClaimers);

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
        assertEq(wrapper.yieldFor(alice), 0, "alice yield not 0");
    }

    function test_claimYield_oneReceiverTwoDepositors() public {
        uint256 principal = 1000e6;

        vm.startPrank(alice);
        deal(address(C.USDC), alice, principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        ERC4626YieldWrapper.Claimer[] memory yieldClaimers = new ERC4626YieldWrapper.Claimer[](1);
        yieldClaimers[0] = ERC4626YieldWrapper.Claimer({account: carol, percent: 1e18});

        wrapper.deposit(principal, yieldClaimers);
        vm.stopPrank();

        vm.startPrank(bob);
        deal(address(C.USDC), bob, principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        yieldClaimers = new ERC4626YieldWrapper.Claimer[](1);
        yieldClaimers[0] = ERC4626YieldWrapper.Claimer({account: carol, percent: 1e18});

        wrapper.deposit(principal, yieldClaimers);
        vm.stopPrank();

        assertEq(wrapper.yieldFor(alice), 0, "alice yield not 0");
        assertEq(wrapper.yieldFor(bob), 0, "bob yield not 0");
        assertEq(wrapper.yieldFor(carol), 0, "carol yield not 0");

        // double the assets in the vault to simulate profit
        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        uint256 expectedYield = principal * 2; // since yield is 100% of principal

        assertEq(wrapper.yieldFor(alice), 0, "alice yield not 0");
        assertEq(wrapper.yieldFor(bob), 0, "bob yield not 0");
        assertEq(wrapper.yieldFor(carol), expectedYield, "carol yield");

        vm.prank(carol);
        wrapper.claimYield();

        assertEq(usdc.balanceOf(carol), expectedYield, "carol balance not correct");
        assertEq(wrapper.yieldFor(alice), 0, "alice yield not 0");
        assertEq(wrapper.yieldFor(bob), 0, "bob yield not 0");
        assertEq(wrapper.yieldFor(carol), 0, "carol yield not 0");
    }

    function test_claimYield_oneDepositorTwoReceivers() public {
        uint256 principal = 1000e6;

        vm.startPrank(alice);
        deal(address(C.USDC), alice, principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        ERC4626YieldWrapper.Claimer[] memory yieldClaimers = new ERC4626YieldWrapper.Claimer[](2);
        yieldClaimers[0] = ERC4626YieldWrapper.Claimer({account: bob, percent: 0.5e18});
        yieldClaimers[1] = ERC4626YieldWrapper.Claimer({account: carol, percent: 0.5e18});

        wrapper.deposit(principal, yieldClaimers);
        vm.stopPrank();

        assertEq(wrapper.yieldFor(alice), 0, "alice yield not 0");
        assertEq(wrapper.yieldFor(bob), 0, "bob yield not 0");
        assertEq(wrapper.yieldFor(carol), 0, "carol yield not 0");

        // double the assets in the vault to simulate profit
        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        uint256 expectedYield = principal / 2; // since yield is 100% of principal

        assertEq(wrapper.yieldFor(alice), 0, "alice yield");
        assertEq(wrapper.yieldFor(bob), expectedYield, "bob yield");
        assertEq(wrapper.yieldFor(carol), expectedYield, "carol yield");

        vm.prank(carol);
        wrapper.claimYield();

        assertEq(usdc.balanceOf(carol), expectedYield, "carol balance not correct");
        assertEq(wrapper.yieldFor(bob), expectedYield, "bob yield");
        assertEq(wrapper.yieldFor(alice), 0, "alice yield");

        vm.prank(bob);
        wrapper.claimYield();

        assertEq(usdc.balanceOf(bob), expectedYield, "bob balance not correct");
        assertEq(wrapper.yieldFor(alice), 0, "alice yield");
    }

    function test_topUp() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), type(uint256).max);

        ERC4626YieldWrapper.Claimer[] memory yieldClaimers = new ERC4626YieldWrapper.Claimer[](1);
        yieldClaimers[0] = ERC4626YieldWrapper.Claimer({account: address(this), percent: 1e18});
        wrapper.deposit(principal, yieldClaimers);

        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        uint256 expectedYield = principal; // since yield is 100% of principal
        assertEq(wrapper.yieldFor(address(this)), expectedYield, "yield not correct");

        deal(address(C.USDC), address(this), principal);
        wrapper.topUp(principal);

        assertEq(wrapper.yieldFor(address(this)), expectedYield, "yield not correct");

        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        // = 2 * principal + 2 * principal
        expectedYield = principal * 4;
        assertApproxEqAbs(wrapper.yieldFor(address(this)), expectedYield, 1, "yield not correct");
    }

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

        aaveV3 = new AaveV3ScUsdcAdapter();
        aaveV2 = new AaveV2ScUsdcAdapter();
        morpho = new MorphoAaveV3ScUsdcAdapter();

        vault.addAdapter(morpho);
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
        Claimer[] yieldClaimers;
    }

    struct Claimer {
        address account;
        uint256 percent;
    }

    ERC4626 vault;
    mapping(address => DepositReceipt) public depositReceipts;
    mapping(address => address[]) public claimerToDepositors;
    mapping(address => uint256) public claimerToPrincipal;

    constructor(ERC4626 _vault) ERC20("Yield Wrapper", "YIELD", 18) {
        vault = _vault;
        vault.asset().approve(address(vault), type(uint256).max);
    }

    // TODO: incomplete, each deposit should be a separate receipt
    function deposit(uint256 _amount, Claimer[] calldata _claimers) public returns (uint256) {
        vault.asset().transferFrom(msg.sender, address(this), _amount);
        uint256 shares = vault.deposit(_amount, address(this));

        DepositReceipt storage receipt = depositReceipts[msg.sender];
        receipt.principal += _amount;

        if (receipt.yieldClaimers.length > 0) revert("already has yield claimers");

        for (uint8 i = 0; i < _claimers.length; i++) {
            Claimer memory claimer = _claimers[i];

            _mint(claimer.account, shares.mulWadDown(claimer.percent));
            claimerToDepositors[claimer.account].push(msg.sender);
            claimerToPrincipal[claimer.account] += _amount.mulWadDown(claimer.percent);
            receipt.yieldClaimers.push(claimer);
        }

        return shares;
    }

    // TODO: incomplete
    function topUp(uint256 _amount) public {
        vault.asset().transferFrom(msg.sender, address(this), _amount);
        uint256 shares = vault.deposit(_amount, address(this));

        DepositReceipt storage receipt = depositReceipts[msg.sender];
        receipt.principal += _amount;

        for (uint8 i = 0; i < receipt.yieldClaimers.length; i++) {
            Claimer memory claimer = receipt.yieldClaimers[i];
            _mint(claimer.account, shares.mulWadDown(claimer.percent));
            claimerToPrincipal[claimer.account] += _amount.mulWadDown(claimer.percent);
        }
    }

    function withdraw(uint256 _principalAmount) public {
        uint256 shares = vault.withdraw(_principalAmount, address(this), address(this));

        vault.asset().transfer(msg.sender, _principalAmount);

        DepositReceipt storage receipt = depositReceipts[msg.sender];
        receipt.principal -= _principalAmount;

        for (uint8 i = 0; i < receipt.yieldClaimers.length; i++) {
            Claimer memory claimer = receipt.yieldClaimers[i];
            _burn(claimer.account, shares.mulWadDown(claimer.percent));

            claimerToPrincipal[claimer.account] -= _principalAmount.mulWadDown(claimer.percent);
        }
    }

    // TODO: problematic because of complex accounting and nested loops
    function transfer(address _to, uint256 _amount) public override returns (bool) {
        bool success = super.transfer(_to, _amount);

        // assume all shares are being transfered
        if (success) {
            address[] storage depositors = claimerToDepositors[msg.sender];
            for (uint8 i = 0; i < depositors.length; i++) {
                address depositor = depositors[i];
                depositors[i] = address(0);
                claimerToDepositors[_to].push(depositor);

                DepositReceipt storage receipt = depositReceipts[depositor];

                for (uint8 j = 0; j < receipt.yieldClaimers.length; j++) {
                    Claimer storage claimer = receipt.yieldClaimers[i];

                    if (claimer.account == msg.sender) {
                        claimer.account = _to;
                        break;
                    }
                }
            }

            claimerToPrincipal[_to] = claimerToPrincipal[msg.sender];
            claimerToPrincipal[msg.sender] = 0;
        }

        return success;
    }

    // TODO: problematic because of complex accounting and nested loops
    function transferFrom(address _from, address _to, uint256 _amount) public override returns (bool) {
        bool success = super.transferFrom(_from, _to, _amount);

        // assume all shares are being transfered
        if (success) {
            address[] storage depositors = claimerToDepositors[_from];
            for (uint8 i = 0; i < depositors.length; i++) {
                address depositor = depositors[i];
                depositors[i] = address(0);
                claimerToDepositors[_to].push(depositor);

                DepositReceipt storage receipt = depositReceipts[depositor];
                for (uint8 j = 0; j < receipt.yieldClaimers.length; j++) {
                    Claimer storage claimer = receipt.yieldClaimers[i];

                    if (claimer.account == _from) {
                        claimer.account = _to;
                        break;
                    }
                }
            }

            claimerToPrincipal[_to] = claimerToPrincipal[_from];
            claimerToPrincipal[_from] = 0;
        }

        return success;
    }

    function claimYield() public returns (uint256) {
        if (claimerToDepositors[msg.sender].length == 0) revert("no yield to claim");

        uint256 yield = _yieldFor(msg.sender);

        if (yield == 0) revert("no yield to claim");

        uint256 shares = vault.withdraw(yield, address(this), address(this));
        vault.asset().transfer(msg.sender, yield);

        _burn(msg.sender, shares);

        return yield;
    }

    function getReceipt(address _account) public view returns (DepositReceipt memory) {
        return depositReceipts[_account];
    }

    function yieldFor(address _account) public view returns (uint256 yield) {
        if (claimerToDepositors[_account].length == 0) {
            return 0;
        }

        return _yieldFor(_account);
    }

    function principalFor(address _account) public view returns (uint256) {
        return depositReceipts[_account].principal;
    }

    function _yieldFor(address _account) internal view returns (uint256) {
        if (vault.totalSupply() == 0) return 0;

        uint256 shares = this.balanceOf(_account);

        if (shares == 0) return 0;

        uint256 pps = vault.totalAssets().divWadDown(vault.totalSupply());

        if (pps == 0) return 0;

        uint256 principal = claimerToPrincipal[_account];

        return shares.mulWadDown(pps) - principal;
    }
}
