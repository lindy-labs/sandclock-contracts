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

    function test_claimYield_toReceiverSecondTime() public {
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

        uint256 shares = wrapper.deposit(principal, alice);

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

        uint256 shares = wrapper.deposit(principal, alice);

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
        assertEq(wrapper.yieldFor(alice), 0, "alice yield not 0");
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
        assertEq(wrapper.yieldFor(alice), 0, "alice yield not 0");
    }

    function test_claimYield_oneReceiverTwoDepositors() public {
        uint256 principal = 1000e6;

        vm.startPrank(alice);
        deal(address(C.USDC), alice, principal);
        ERC20(C.USDC).approve(address(wrapper), principal);
        wrapper.deposit(principal, carol);
        vm.stopPrank();

        vm.startPrank(bob);
        deal(address(C.USDC), bob, principal);
        ERC20(C.USDC).approve(address(wrapper), principal);
        wrapper.deposit(principal, carol);
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
        address[] memory claimers = new address[](2);
        claimers[0] = bob;
        claimers[1] = carol;
        uint256[] memory percentages = new uint256[](2);
        percentages[0] = 0.5e18;
        percentages[1] = 0.5e18;
        wrapper.deposit(principal, claimers, percentages);
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
        Yield[] yields;
    }

    struct Yield {
        address claimer;
        uint256 percent;
    }

    function getReceipt(address _account) public view returns (DepositReceipt memory) {
        return depositReceipts[_account];
    }

    ERC4626 vault;
    mapping(address => DepositReceipt) public depositReceipts;
    mapping(address => address[]) public receiverToDepositors;

    constructor(ERC4626 _vault) ERC20("Yield Wrapper", "YIELD", 18) {
        vault = _vault;
        vault.asset().approve(address(vault), type(uint256).max);
    }

    function deposit(uint256 _amount, address _yieldReceiver) public returns (uint256) {
        vault.asset().transferFrom(msg.sender, address(this), _amount);
        uint256 shares = vault.deposit(_amount, address(this));

        DepositReceipt storage receipt = depositReceipts[msg.sender];
        receipt.principal += _amount;

        receiverToDepositors[_yieldReceiver].push(msg.sender);

        // TODO: consider top-ups
        receipt.yields.push(Yield({claimer: _yieldReceiver, percent: 1e18}));

        _mint(_yieldReceiver, shares);

        return shares;
    }

    function deposit(uint256 _amount, address[] calldata _yieldReceivers, uint256[] calldata _percent)
        public
        returns (uint256)
    {
        vault.asset().transferFrom(msg.sender, address(this), _amount);
        uint256 shares = vault.deposit(_amount, address(this));

        DepositReceipt storage receipt = depositReceipts[msg.sender];
        receipt.principal += _amount;
        for (uint8 i = 0; i < _yieldReceivers.length; i++) {
            _mint(_yieldReceivers[i], shares.mulWadDown(_percent[i]));
            receiverToDepositors[_yieldReceivers[i]].push(msg.sender);
            receipt.yields.push(Yield({claimer: _yieldReceivers[i], percent: _percent[i]}));
        }

        return shares;
    }

    function withdraw(uint256 _principalAmount) public {
        uint256 shares = vault.withdraw(_principalAmount, address(this), address(this));

        vault.asset().transfer(msg.sender, _principalAmount);

        DepositReceipt storage receipt = depositReceipts[msg.sender];
        receipt.principal -= _principalAmount;

        for (uint8 i = 0; i < receipt.yields.length; i++) {
            _burn(receipt.yields[i].claimer, shares.mulWadDown(receipt.yields[i].percent));
        }
    }

    function transfer(address _to, uint256 _amount) public override returns (bool) {
        bool success = super.transfer(_to, _amount);

        // assume all shares are being transfered
        if (success) {
            address[] storage depositors = receiverToDepositors[msg.sender];
            for (uint8 i = 0; i < depositors.length; i++) {
                address depositor = depositors[i];
                depositors[i] = address(0);
                receiverToDepositors[_to].push(depositor);

                DepositReceipt storage receipt = depositReceipts[depositor];
                for (uint8 j = 0; j < receipt.yields.length; j++) {
                    if (receipt.yields[j].claimer == msg.sender) {
                        receipt.yields[j].claimer = _to;
                        break;
                    }
                }
            }
        }

        return success;
    }

    function transferFrom(address _from, address _to, uint256 _amount) public override returns (bool) {
        bool success = super.transferFrom(_from, _to, _amount);

        // assume all shares are being transfered
        if (success) {
            address[] storage depositors = receiverToDepositors[_from];
            for (uint8 i = 0; i < depositors.length; i++) {
                address depositor = depositors[i];
                depositors[i] = address(0);
                receiverToDepositors[_to].push(depositor);

                DepositReceipt storage receipt = depositReceipts[depositor];
                for (uint8 j = 0; j < receipt.yields.length; j++) {
                    if (receipt.yields[j].claimer == _from) {
                        receipt.yields[j].claimer = _to;
                        break;
                    }
                }
            }
        }

        return success;
    }

    function claimYield() public returns (uint256) {
        if (receiverToDepositors[msg.sender].length == 0) revert("no yield to claim");

        uint256 pps = currentPricePerShare();
        uint256 yield = _yieldFor(msg.sender, pps);

        if (yield == 0) revert("no yield to claim");

        uint256 shares = vault.withdraw(yield, address(this), address(this));
        vault.asset().transfer(msg.sender, yield);

        _burn(msg.sender, shares);

        return yield;
    }

    function yieldFor(address _account) public view returns (uint256 yield) {
        uint256 pps = currentPricePerShare();
        if (pps == 0) return 0;

        if (receiverToDepositors[_account].length == 0) {
            return 0;
        }

        return _yieldFor(_account, pps);
    }

    function principalFor(address _account) public view returns (uint256) {
        return depositReceipts[_account].principal;
    }

    function currentPricePerShare() public view returns (uint256) {
        if (vault.totalSupply() == 0) return 0;

        return vault.totalAssets().divWadDown(vault.totalSupply());
    }

    function _yieldFor(address _account, uint256 _pps) internal view returns (uint256) {
        if (_pps == 0) return 0;

        uint256 shares = this.balanceOf(_account);

        if (shares == 0) return 0;

        uint256 principal;
        for (uint8 i = 0; i < receiverToDepositors[_account].length; i++) {
            if (receiverToDepositors[_account][i] == address(0)) continue;

            DepositReceipt memory receipt = depositReceipts[receiverToDepositors[_account][i]];

            for (uint8 j = 0; j < receipt.yields.length; j++) {
                if (receipt.yields[j].claimer == _account) {
                    principal += receipt.principal.mulWadDown(receipt.yields[j].percent);
                    break;
                }
            }
        }

        return shares.mulWadDown(_pps) - principal;
    }
}
