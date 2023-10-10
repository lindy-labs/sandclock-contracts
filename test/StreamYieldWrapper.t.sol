// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {EnumerableSet} from "openzeppelin-contracts/utils/structs/EnumerableSet.sol";
import {EnumerableMap} from "openzeppelin-contracts/utils/structs/EnumerableMap.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";
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

contract StreamYieldWrapperTest is Test {
    using FixedPointMathLib for uint256;
    using Strings for string;

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

    StreamYieldWrapper wrapper;

    function setUp() public {
        mainnetFork = vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(17529069);

        usdc = ERC20(C.USDC);
        weth = WETH(payable(C.WETH));

        _deployScWeth();
        _deployAndSetUpVault();
        wrapper = new StreamYieldWrapper(vault);
    }

    function test_claimYield_toSelf() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        wrapper.open(principal, address(this));

        assertEq(wrapper.yieldFor(address(this)), 0, "yield not 0 after deposit");
        // assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");

        // double the assets in the vault to simulate profit
        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        uint256 expectedYield = principal; // since yield is 100% of principal
        uint256 yield = wrapper.yieldFor(address(this));

        assertEq(yield, expectedYield, "yield not correct");

        uint256 claimedAmount = wrapper.claimYield(address(this));

        assertEq(claimedAmount, usdc.balanceOf(address(this)), "claimed amount not correct");
        assertEq(wrapper.yieldFor(address(this)), 0, "yield not 0 after claim");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");
    }

    function test_claimYield_toReceiver() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        wrapper.open(principal, alice);

        assertEq(wrapper.yieldFor(address(this)), 0, "yield not 0 after deposit");
        assertEq(wrapper.yieldFor(alice), 0, "receiver yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");

        // double the assets in the vault to simulate profit
        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        uint256 expectedYield = principal; // since yield is 100% of principal

        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(alice), expectedYield, "receiver yield 0");

        vm.prank(alice);
        wrapper.claimYield(alice);

        assertEq(usdc.balanceOf(alice), expectedYield, "alice balance not correct");
        assertEq(wrapper.yieldFor(alice), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");
    }

    function test_claimYield_toReceiverSecondTime() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        wrapper.open(principal, alice);

        assertEq(wrapper.yieldFor(address(this)), 0, "yield not 0 after deposit");
        assertEq(wrapper.yieldFor(alice), 0, "receiver yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");

        // double the assets in the vault to simulate profit
        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        uint256 expectedYield = principal; // since yield is 100% of principal

        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(alice), expectedYield, "receiver yield 0");

        vm.prank(alice);
        wrapper.claimYield(alice);

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
        wrapper.claimYield(alice);

        assertEq(usdc.balanceOf(alice), expectedYield * 2, "alice balance not correct");
        assertEq(wrapper.yieldFor(alice), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");
    }

    function test_claimYield_whenInLoss() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        wrapper.open(principal, address(this));

        assertEq(wrapper.yieldFor(address(this)), 0, "yield not 0 after deposit");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");

        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) / 2);

        assertEq(wrapper.yieldFor(address(this)), 0, "yield not correct");
        assertEq(wrapper.principalFor(address(this)), principal / 2, "principal");

        // vm.expectRevert();
        wrapper.claimYield(address(this));

        wrapper.close(address(this));

        assertEq(usdc.balanceOf(address(this)), principal / 2, "balance not correct");
        assertEq(wrapper.yieldFor(address(this)), 0, "yield not 0 after claim");
        assertEq(wrapper.principalFor(address(this)), 0, "principal");
    }

    function test_claimYield_receiverTransfersSharesToAnotherAccount() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        uint256 shares = wrapper.open(principal, alice);

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
        wrapper.claimYield(bob);

        assertEq(usdc.balanceOf(bob), expectedYield, "bob balance not correct");
        assertEq(wrapper.yieldFor(alice), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(bob), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");
    }

    // function test_transferFrom_() public {
    //     uint256 principal = 1000e6;
    //     deal(address(C.USDC), address(this), principal);
    //     ERC20(C.USDC).approve(address(wrapper), principal);

    //     uint256 shares = wrapper.deposit(principal, alice);

    //     assertEq(wrapper.balanceOf(alice), shares, "alice shares");
    //     assertEq(wrapper.yieldFor(alice), 0, "receiver yield not 0");
    //     assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");

    //     // double the assets in the vault to simulate profit
    //     deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

    //     uint256 expectedYield = principal; // since yield is 100% of principal
    //     vm.prank(alice);
    //     wrapper.approve(bob, shares);

    //     vm.prank(bob);
    //     wrapper.transferFrom(alice, bob, shares);

    //     assertEq(wrapper.balanceOf(alice), 0, "alice shares");
    //     assertEq(wrapper.balanceOf(bob), shares, "bob shares");

    //     assertEq(wrapper.yieldFor(alice), 0, "depositor yield not 0");
    //     assertEq(wrapper.yieldFor(bob), expectedYield, "receiver yield 0");

    //     vm.prank(bob);
    //     wrapper.claimYield();

    //     assertEq(usdc.balanceOf(bob), expectedYield, "bob balance not correct");
    //     assertEq(wrapper.yieldFor(alice), 0, "depositor yield not 0");
    //     assertEq(wrapper.yieldFor(bob), 0, "depositor yield not 0");
    //     assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
    //     assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");
    // }

    function test_claimYield_depositorWithdrawsBeforeYieldClaimed() public {
        uint256 principal = 1000e6;
        deal(address(C.USDC), address(this), principal);
        ERC20(C.USDC).approve(address(wrapper), principal);

        wrapper.open(principal, alice);

        assertEq(wrapper.yieldFor(address(this)), 0, "yield not 0 after deposit");
        assertEq(wrapper.yieldFor(alice), 0, "receiver yield not 0");
        assertEq(wrapper.principalFor(address(this)), principal, "principal != deposit");

        // double the assets in the vault to simulate profit
        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        uint256 expectedYield = principal; // since yield is 100% of principal

        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(alice), expectedYield, "receiver yield 0");

        wrapper.principalFor(address(this));
        wrapper.close(alice);

        assertEq(usdc.balanceOf(address(this)), principal, "depositor balance not correct after withraw");
        assertEq(wrapper.principalFor(address(this)), 0, "principal != 0 after withdraw");
        assertEq(wrapper.yieldFor(address(this)), 0, "depositor yield not 0");
        assertEq(wrapper.yieldFor(alice), expectedYield, "receiver yield ");

        vm.prank(alice);
        wrapper.claimYield(alice);

        assertEq(usdc.balanceOf(alice), expectedYield, "alice balance not correct");
        assertEq(wrapper.yieldFor(alice), 0, "alice yield not 0");
    }

    function test_claimYield_oneReceiverTwoDepositors() public {
        uint256 principal = 1000e6;

        vm.startPrank(alice);
        deal(address(C.USDC), alice, principal);
        ERC20(C.USDC).approve(address(wrapper), principal);
        wrapper.open(principal, carol);
        vm.stopPrank();

        vm.startPrank(bob);
        deal(address(C.USDC), bob, principal);
        ERC20(C.USDC).approve(address(wrapper), principal);
        wrapper.open(principal, carol);
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
        wrapper.claimYield(carol);

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

        wrapper.open(principal / 2, bob);
        wrapper.open(principal / 2, carol);

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
        wrapper.claimYield(carol);

        assertEq(usdc.balanceOf(carol), expectedYield, "carol balance not correct");
        assertEq(wrapper.yieldFor(bob), expectedYield, "bob yield");
        assertEq(wrapper.yieldFor(alice), 0, "alice yield");

        vm.prank(bob);
        wrapper.claimYield(bob);

        assertEq(usdc.balanceOf(bob), expectedYield, "bob balance not correct");
        assertEq(wrapper.yieldFor(alice), 0, "alice yield");
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

contract StreamYieldWrapper is ERC20 {
    using FixedPointMathLib for uint256;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    ERC4626 public vault;

    // total principal for a yield beneficiary (ie not claimable)
    mapping(address => uint256) public receiverPrincipal;

    // total principal of an address to a yield beneficiary
    mapping(address => mapping(address => uint256)) public deposited;

    mapping(address => uint256) public depositorPrincipal;
    mapping(address => EnumerableSet.AddressSet) depositorToReceivers;

    constructor(ERC4626 _vault) ERC20("Yield Wrapper", "YIELD", 18) {
        vault = _vault;
        vault.asset().approve(address(vault), type(uint256).max);
    }

    // TODO: batch open?
    function open(uint256 _amount, address _yieldReceiver) public returns (uint256) {
        vault.asset().transferFrom(msg.sender, address(this), _amount);
        uint256 shares = vault.deposit(_amount, address(this));

        _mint(_yieldReceiver, shares);

        deposited[_yieldReceiver][msg.sender] += _amount;
        receiverPrincipal[_yieldReceiver] += _amount;
        depositorPrincipal[msg.sender] += _amount;
        depositorToReceivers[msg.sender].add(_yieldReceiver);

        return shares;
    }

    // TODO: batch close?
    function close(address _yieldReceiver) public returns (uint256) {
        uint256 assets = deposited[_yieldReceiver][msg.sender];

        uint256 ask = vault.convertToShares(assets);

        uint256 have = this.balanceOf(_yieldReceiver).mulDivDown(assets, receiverPrincipal[_yieldReceiver]);

        // if there was a loss, withdraw the percentage of the shares
        // equivalent to the sender share of the total principal
        uint256 shares = ask > have ? have : ask;

        receiverPrincipal[_yieldReceiver] -= assets;
        deposited[_yieldReceiver][msg.sender] = 0;
        depositorPrincipal[msg.sender] -= assets;
        depositorToReceivers[msg.sender].remove(_yieldReceiver);

        _burn(_yieldReceiver, shares);

        vault.redeem(shares, msg.sender, address(this));
    }

    function claimYield(address receiver) external returns (uint256) {
        uint256 yield = yieldFor(msg.sender);
        uint256 shares = vault.withdraw(yield, receiver, address(this));

        _burn(msg.sender, shares);

        return yield;
    }

    function transfer(address _to, uint256 _amount) public override returns (bool) {
        bool success = super.transfer(_to, _amount);
        uint256 assets = vault.convertToAssets(_amount);

        // TODO: to transfer shares we need to find the link to depositor(s)

        receiverPrincipal[msg.sender] -= assets;
        receiverPrincipal[_to] += assets;

        return success;
    }

    function yieldFor(address _account) public view returns (uint256) {
        if (vault.totalSupply() == 0) return 0;

        uint256 shares = this.balanceOf(_account);

        if (shares == 0) return 0;

        uint256 pps = vault.totalAssets().divWadDown(vault.totalSupply());

        if (pps == 0) return 0;

        // check if yield is negative
        if (shares.mulWadDown(pps) < receiverPrincipal[_account]) return 0;

        return shares.mulWadDown(pps) - receiverPrincipal[_account];
    }

    function principalFor(address _account) public view returns (uint256 p) {
        for (uint8 i = 0; i < depositorToReceivers[_account].length(); i++) {
            address receiver = depositorToReceivers[_account].at(i);
            uint256 deposit = deposited[receiver][_account];
            uint256 assets = vault.convertToAssets(this.balanceOf(receiver));

            p += assets < deposit ? assets : deposit;
        }
    }

    function receiversFor(address _account) public view returns (address[] memory) {
        address[] memory receivers = new address[](depositorToReceivers[_account].length());

        for (uint8 i = 0; i < depositorToReceivers[_account].length(); i++) {
            receivers[i] = depositorToReceivers[_account].at(i);
        }

        return receivers;
    }
}
