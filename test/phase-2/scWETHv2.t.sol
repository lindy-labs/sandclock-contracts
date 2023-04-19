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

import {Constants as C} from "../../src/lib/Constants.sol";
import {scWETHv2} from "../../src/phase-2/scWETHv2.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../../src/interfaces/lido/ILido.sol";
import {IwstETH} from "../../src/interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../../src/interfaces/curve/ICurvePool.sol";
import {IVault} from "../../src/interfaces/balancer/IVault.sol";
import {AggregatorV3Interface} from "../../src/interfaces/chainlink/AggregatorV3Interface.sol";
import {sc4626} from "../../src/sc4626.sol";
import "../../src/errors/scErrors.sol";

contract scWETHv2Test is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);
    address constant treasury = address(0x07);
    uint256 boundMinimum = 1e10; // below this amount, aave doesn't count it as collateral

    address admin = address(this);
    scWETHv2 vault;
    uint256 initAmount = 100e18;

    WETH weth;
    ILido stEth;
    IwstETH wstEth;
    IAToken aToken;
    ERC20 debtToken;
    IPool aavePool;
    ICurvePool curvePool;
    uint256 slippageTolerance = 0.99e18;
    uint256 maxLtv;
    uint256 targetLtv = 0.7e18;

    function setUp() public {
        vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(16784444);

        scWETHv2.ConstructorParams memory params = _createDefaultWethv2VaultConstructorParams();

        vault = new scWETHv2(params);

        // set vault eth balance to zero
        vm.deal(address(vault), 0);

        weth = vault.weth();
        stEth = vault.stEth();
        wstEth = vault.wstETH();
        curvePool = vault.curvePool();
    }

    function test_constructor() public {
        assertEq(vault.hasRole(vault.DEFAULT_ADMIN_ROLE(), admin), true, "admin role not set");
        assertEq(vault.hasRole(vault.KEEPER_ROLE(), keeper), true, "keeper role not set");
        assertEq(address(vault.weth()), C.WETH);
        assertEq(address(vault.stEth()), C.STETH);
        assertEq(address(vault.wstETH()), C.WSTETH);
        assertEq(address(vault.curvePool()), C.CURVE_ETH_STETH_POOL);
        assertEq(address(vault.balancerVault()), C.BALANCER_VAULT);
        assertEq(address(vault.stEThToEthPriceFeed()), C.CHAINLINK_STETH_ETH_PRICE_FEED);
        assertEq(vault.slippageTolerance(), slippageTolerance);
    }

    function test_deposit_redeem(uint256 amount) public {
        amount = bound(amount, boundMinimum, 1e27);
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.approve(address(vault), amount);

        uint256 preDepositBal = weth.balanceOf(address(this));

        vault.deposit(amount, address(this));

        _depositChecks(amount, preDepositBal);

        vault.redeem(vault.balanceOf(address(this)), address(this), address(this));

        _redeemChecks(preDepositBal);
    }

    function test_rebalancePosition_reallocation() public {}

    function test_rebalancePosition_reinvestingProfits() public {}

    // we decrease ltv in case of a loss, since the ltv goes higher than the target ltv in such a scenario
    function test_rebalancePosition_decreasingLtv() public {}

    //////////////////////////// INTERNAL METHODS ////////////////////////////////////////

    function _depositChecks(uint256 amount, uint256 preDepositBal) internal {
        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.totalAssets(), amount);
        assertEq(vault.balanceOf(address(this)), amount);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), amount);
        assertEq(weth.balanceOf(address(this)), preDepositBal - amount);
    }

    function _redeemChecks(uint256 preDepositBal) internal {
        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), 0);
        assertEq(weth.balanceOf(address(this)), preDepositBal);
    }

    function _depositToVault(address user, uint256 amount) internal returns (uint256 shares) {
        deal(address(weth), user, amount);
        vm.startPrank(user);
        weth.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        vm.stopPrank();
    }

    function _createDefaultWethv2VaultConstructorParams() internal view returns (scWETHv2.ConstructorParams memory) {
        return scWETHv2.ConstructorParams({
            admin: admin,
            keeper: keeper,
            slippageTolerance: slippageTolerance,
            curveEthStEthPool: ICurvePool(C.CURVE_ETH_STETH_POOL),
            stEth: ILido(C.STETH),
            wstEth: IwstETH(C.WSTETH),
            weth: WETH(payable(C.WETH)),
            stEthToEthPriceFeed: AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED),
            balancerVault: IVault(C.BALANCER_VAULT)
        });
    }
}
