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

contract SimpleYieldWrapperTest is Test {
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

    SimpleYieldWrapper wrapper;
    ERC20YieldWrapper erc20Wrapper;

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
        wrapper = new SimpleYieldWrapper(vault);
    }

    /// #constructor ///

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

    function test_1() public {
        deal(address(C.USDC), address(this), 1000e6);
        ERC20(C.USDC).approve(address(wrapper), 1000e6);

        wrapper.deposit(1000e6, address(this));

        uint256 yield = wrapper.yieldFor(address(this));
        console2.log("yield", yield);

        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        yield = wrapper.yieldFor(address(this));
        console2.log("yield", yield);

        console2.log("usdc balance", ERC20(C.USDC).balanceOf(address(this)));

        wrapper.claimYield();

        console2.log("usdc balance", ERC20(C.USDC).balanceOf(address(this)));

        // deal(address(C.USDC), address(this), 1000e6);
        // ERC20(C.USDC).approve(address(wrapper), 1000e6);

        // wrapper.deposit(1000e6, address(this));

        uint256 principalAmount = wrapper.principalFor(address(this));
        wrapper.withdraw(principalAmount);

        console2.log("depositor balance", ERC20(C.USDC).balanceOf(address(this)));
        console2.log("depositor yield", wrapper.yieldFor(address(this)));
        console2.log("depositor princial", wrapper.principalFor(address(this)));
    }

    function test_2() public {
        deal(address(C.USDC), address(this), 1000e6);
        ERC20(C.USDC).approve(address(wrapper), 1000e6);

        wrapper.deposit(1000e6, alice);

        uint256 yield = wrapper.yieldFor(address(this));
        console2.log("depositor yield", yield);

        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        yield = wrapper.yieldFor(alice);
        console2.log("alice yield", yield);

        console2.log("depositor balance", ERC20(C.USDC).balanceOf(address(this)));

        vm.prank(alice);
        wrapper.claimYield();

        console2.log("depositor balance", ERC20(C.USDC).balanceOf(address(this)));
        uint256 principalAmount = wrapper.principalFor(address(this));
        wrapper.withdraw(principalAmount);

        console2.log("depositor balance", ERC20(C.USDC).balanceOf(address(this)));
        console2.log("depositor yield", wrapper.yieldFor(address(this)));
        console2.log("depositor princial", wrapper.principalFor(address(this)));
        console2.log("alice yield", wrapper.yieldFor(alice));
        console2.log("alice balance", ERC20(C.USDC).balanceOf(alice));
    }

    function test_3() public {
        deal(address(C.USDC), address(this), 1000e6);
        ERC20(C.USDC).approve(address(wrapper), 1000e6);

        wrapper.deposit(1000e6, alice);

        console2.log("depositor yield", wrapper.yieldFor(address(this)));

        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        console2.log("depositor balance", ERC20(C.USDC).balanceOf(address(this)));

        uint256 principalAmount = wrapper.principalFor(address(this));
        wrapper.withdraw(principalAmount);

        console2.log("depositor balance", ERC20(C.USDC).balanceOf(address(this)));
        console2.log("depositor yield", wrapper.yieldFor(address(this)));
        console2.log("depositor princial", wrapper.principalFor(address(this)));
        console2.log("alice yield", wrapper.yieldFor(alice));
        console2.log("alice balance", ERC20(C.USDC).balanceOf(alice));

        console2.log("alice claims");
        vm.prank(alice);
        wrapper.claimYield();

        console2.log("alice yield", wrapper.yieldFor(alice));
        console2.log("alice balance", ERC20(C.USDC).balanceOf(alice));
    }

    function test_4() public {
        deal(address(C.USDC), address(this), 1000e6);
        ERC20(C.USDC).approve(address(wrapper), 1000e6);

        wrapper.deposit(1000e6, alice);

        console2.log("depositor yield", wrapper.yieldFor(address(this)));

        deal(address(C.USDC), address(vault), ERC20(C.USDC).balanceOf(address(vault)) * 2);

        console2.log("depositor balance", ERC20(C.USDC).balanceOf(address(this)));

        uint256 principalAmount = wrapper.principalFor(address(this));
        wrapper.withdraw(principalAmount / 2);

        console2.log("depositor balance", ERC20(C.USDC).balanceOf(address(this)));
        console2.log("depositor yield", wrapper.yieldFor(address(this)));
        console2.log("depositor princial", wrapper.principalFor(address(this)));
        console2.log("alice yield", wrapper.yieldFor(alice));
        console2.log("alice balance", ERC20(C.USDC).balanceOf(alice));

        console2.log("alice claims");
        vm.prank(alice);
        wrapper.claimYield();

        console2.log("alice yield", wrapper.yieldFor(alice));
        console2.log("alice balance", ERC20(C.USDC).balanceOf(alice));
    }
}

contract ERC20YieldWrapper is ERC20 {
    using FixedPointMathLib for uint256;

    struct DepositReceipt {
        uint256 principal;
        address owner;
        uint256 pps;
        uint256 shares;
        address yieldReceiver;
    }

    scUSDCv2 vault;
    mapping(address => DepositReceipt) public depositReceitps;
    mapping(address => DepositReceipt) public receiverToDepositReceipt;

    constructor(scUSDCv2 _vault) ERC20("Yield Wrapper", "YIELD", 18) {
        vault = _vault;
        ERC20(C.USDC).approve(address(vault), type(uint256).max);
    }

    function deposit(uint256 _amount, address _yieldReceiver) public {
        ERC20(C.USDC).transferFrom(msg.sender, address(this), _amount);
        uint256 shares = vault.deposit(_amount, address(this));
        uint256 pps = vault.totalAssets().divWadDown(vault.totalSupply());
        console2.log("pps", pps);

        DepositReceipt memory receipt = DepositReceipt({
            principal: _amount,
            owner: msg.sender,
            pps: pps,
            shares: shares,
            yieldReceiver: _yieldReceiver
        });

        depositReceitps[msg.sender] = receiverToDepositReceipt[_yieldReceiver] = receipt;
        _mint(_yieldReceiver, shares);
    }

    function withdraw(uint256 _principalAmount) public {
        DepositReceipt storage receipt = depositReceitps[msg.sender];
        uint256 shares = vault.withdraw(_principalAmount, address(this), address(this));
        ERC20(C.USDC).transfer(msg.sender, _principalAmount);
        receipt.principal -= _principalAmount;
        receipt.shares -= shares;
    }

    function yieldFor(address _account) public view returns (uint256) {
        uint256 pps = currentPps();
        DepositReceipt memory receipt = receiverToDepositReceipt[_account];

        if (pps == 0) return 0;

        if (receipt.shares == 0) return 0;

        uint256 depositorShares = receipt.shares;
        uint256 depositedPps = receipt.pps;

        return depositorShares.mulWadDown(pps - depositedPps);
    }

    function principalFor(address _account) public view returns (uint256) {
        return depositReceitps[_account].principal;
    }

    function currentPps() public view returns (uint256) {
        if (vault.totalSupply() == 0) return 0;

        return vault.totalAssets().divWadDown(vault.totalSupply());
    }

    function claimYield() public {
        uint256 yield = yieldFor(msg.sender);
        DepositReceipt storage receipt = depositReceitps[receiverToDepositReceipt[msg.sender].owner];

        uint256 shares = vault.withdraw(yield, address(this), address(this));
        receipt.shares -= shares;
        ERC20(C.USDC).transfer(msg.sender, yield);
    }
}

contract SimpleYieldWrapper {
    using FixedPointMathLib for uint256;

    struct DepositReceipt {
        uint256 principal;
        address owner;
        uint256 pps;
        uint256 shares;
        address yieldReceiver;
    }

    scUSDCv2 vault;
    mapping(address => DepositReceipt) public depositReceitps;
    mapping(address => DepositReceipt) public receiverToDepositReceipt;

    constructor(scUSDCv2 _vault) {
        vault = _vault;
        ERC20(C.USDC).approve(address(vault), type(uint256).max);
    }

    function deposit(uint256 _amount, address _yieldReceiver) public {
        ERC20(C.USDC).transferFrom(msg.sender, address(this), _amount);
        uint256 shares = vault.deposit(_amount, address(this));
        uint256 pps = vault.totalAssets().divWadDown(vault.totalSupply());
        console2.log("pps", pps);

        DepositReceipt memory receipt = DepositReceipt({
            principal: _amount,
            owner: msg.sender,
            pps: pps,
            shares: shares,
            yieldReceiver: _yieldReceiver
        });

        depositReceitps[msg.sender] = receiverToDepositReceipt[_yieldReceiver] = receipt;
    }

    function withdraw(uint256 _principalAmount) public {
        DepositReceipt storage receipt = depositReceitps[msg.sender];
        uint256 shares = vault.withdraw(_principalAmount, address(this), address(this));
        ERC20(C.USDC).transfer(msg.sender, _principalAmount);
        receipt.principal -= _principalAmount;
        receipt.shares -= shares;
    }

    function yieldFor(address _account) public view returns (uint256) {
        uint256 pps = currentPps();
        DepositReceipt memory receipt = receiverToDepositReceipt[_account];

        if (pps == 0) return 0;

        if (receipt.shares == 0) return 0;

        uint256 depositorShares = receipt.shares;
        uint256 depositedPps = receipt.pps;

        return depositorShares.mulWadDown(pps - depositedPps);
    }

    function principalFor(address _account) public view returns (uint256) {
        return depositReceitps[_account].principal;
    }

    function currentPps() public view returns (uint256) {
        if (vault.totalSupply() == 0) return 0;

        return vault.totalAssets().divWadDown(vault.totalSupply());
    }

    function claimYield() public {
        uint256 yield = yieldFor(msg.sender);
        DepositReceipt storage receipt = depositReceitps[receiverToDepositReceipt[msg.sender].owner];

        uint256 shares = vault.withdraw(yield, address(this), address(this));
        receipt.shares -= shares;
        ERC20(C.USDC).transfer(msg.sender, yield);
    }
}
