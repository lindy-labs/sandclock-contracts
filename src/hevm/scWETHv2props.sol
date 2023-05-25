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

import {Constants as C} from "../lib/Constants.sol";
import {scWETHv2Harness} from "./harness/scWETHv2Harness.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../interfaces/lido/ILido.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {sc4626} from "../sc4626.sol";
import {scWETHv2Helper} from "../phase-2/scWETHv2Helper.sol";
import {OracleLib} from "../phase-2/OracleLib.sol";
//import "../errors/scErrors.sol";

import {IAdapter} from "../scWeth-adapters/IAdapter.sol";
import {AaveV3Adapter} from "../scWeth-adapters/AaveV3Adapter.sol";
import {CompoundV3Adapter} from "../scWeth-adapters/CompoundV3Adapter.sol";
import {EulerAdapter} from "../scWeth-adapters/EulerAdapter.sol";
import {ISwapRouter} from "../swap-routers/ISwapRouter.sol";
import {WethToWstEthSwapRouter} from "../swap-routers/WethToWstEthSwapRouter.sol";
import {WstEthToWethSwapRouter} from "../swap-routers/WstEthToWethSwapRouter.sol";

import {MockWETH} from "../../test/mocks/MockWETH.sol";


contract scWETHv2Props is Test {
    using FixedPointMathLib for uint256;
    using Address for address;

    uint256 constant BLOCK_BEFORE_EULER_EXPLOIT = 16784444;
    uint256 constant BLOCK_AFTER_EULER_EXPLOIT = 17243956;

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);
    address constant treasury = address(0x07);
    uint256 boundMinimum = 1.5 ether; // below this amount, aave doesn't count it as collateral

    address admin = address(this);
    scWETHv2Harness vault;
    scWETHv2Helper vaultHelper;
    OracleLib oracleLib;
    uint256 initAmount = 100e18;

    uint256 aaveV3AllocationPercent = 0.5e18;
    uint256 eulerAllocationPercent = 0.3e18;
    uint256 compoundAllocationPercent = 0.2e18;

    uint256 slippageTolerance = 0.99e18;
    uint256 maxLtv;
    MockWETH weth;
    ILido stEth;
    IwstETH wstEth;
    AggregatorV3Interface public stEThToEthPriceFeed;
    uint256 minimumFloatAmount;

    mapping(IAdapter => uint256) targetLtv;

    uint8 aaveV3AdapterId;
    uint8 eulerAdapterId;
    uint8 compoundV3AdapterId;

    IAdapter aaveV3Adapter;
    IAdapter eulerAdapter;
    IAdapter compoundV3Adapter;

    function setUp() public { //uint256 _blockNumber) internal {
        /*vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(_blockNumber);*/

        weth = new MockWETH();
        oracleLib = _deployOracleLib();
        scWETHv2Harness.ConstructorParams memory params = _createDefaultWethv2VaultConstructorParams(oracleLib);
        vault = new scWETHv2Harness(params);
        //vaultHelper = new scWETHv2Helper(vault, oracleLib);

        //weth = WETH(payable(address(vault.asset())));
        stEth = ILido(C.STETH);
        wstEth = IwstETH(C.WSTETH);
        stEThToEthPriceFeed = AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED);
        minimumFloatAmount = vault.minimumFloatAmount();

        // set vault eth balance to zero
        //vm.deal(address(vault), 0);

        _setupAdapters(0);//_blockNumber);

        targetLtv[aaveV3Adapter] = 0.7e18;
        targetLtv[compoundV3Adapter] = 0.7e18;

        //if (_blockNumber == BLOCK_BEFORE_EULER_EXPLOIT) {
            targetLtv[eulerAdapter] = 0.5e18;
        //}
    }

    function _setupAdapters(uint256 _blockNumber) internal {
        // add adaptors
        aaveV3Adapter = new AaveV3Adapter();
        compoundV3Adapter = new CompoundV3Adapter();

        //vault.addAdapter(address(aaveV3Adapter));
        //vault.addAdapter(address(compoundV3Adapter));

        aaveV3AdapterId = aaveV3Adapter.id();
        compoundV3AdapterId = compoundV3Adapter.id();

        if (_blockNumber == BLOCK_BEFORE_EULER_EXPLOIT) {
            eulerAdapter = new EulerAdapter();
            vault.addAdapter(address(eulerAdapter));
            eulerAdapterId = eulerAdapter.id();
        }
    }
    function prove_integrity_of_setSlippageTolerance(uint256 newslippageTolerance) public { // OK
        if(newslippageTolerance <= C.ONE) {
            vault.setSlippageTolerance(newslippageTolerance);
            assertEq(vault.slippageTolerance(), newslippageTolerance);
        }
    }

    function prove_reverts_setSlippageTolerance(uint256 newslippageTolerance) public { // OK
        if(newslippageTolerance > C.ONE) {
            try vault.setSlippageTolerance(newslippageTolerance) {
                assert(false);
            }
            catch {
                assert(true);
            }
        }
    }
    
    function prove_integrity_of_setMinimumFloatAmount(uint256 newFloatAmount) public { // OK
        vault.setMinimumFloatAmount(newFloatAmount);
        assertEq(vault.minimumFloatAmount(), newFloatAmount);
    }

    function prove_integrity_of_setTreasury(address newTreasury) public { // OK
	    if(newTreasury != address(0)) {
		    vault.setTreasury(newTreasury);
		    assertEq(vault.treasury(), newTreasury, "prove_integrity_of_setTreasury");
	    }
    }

    function prove_setTreasury_reverts_if_address_is_zero() public { // OK
	    try vault.setTreasury(address(0)) {
		    assert(false);
	    }
	    catch {
		    assert(true);
	    }
    }

    function prove_convertToAssets_rounds_down_towards_0(uint256 shares) public { // OK
    	if(vault.totalSupply() != 0) {
	        assertEq((shares * vault.totalAssets()) / vault.totalSupply(), vault.convertToAssets(shares), "convertToAssets_rounds_down_towards_0");
	    }
    } 

    function prove_converToShares_rounds_down_towards_0(uint256 assets) public {
        if(vault.totalSupply() != 0)
            assertEq((assets * vault.totalSupply()) / vault.totalAssets(), vault.convertToShares(assets));
    }
    
    function prove_maxDeposit_returns_correct_value(address receiver) public { // OK
    	if(receiver != address(0)) {
	    	assertEq(vault.maxDeposit(receiver), 2**256 - 1, "maxDeposit_returns_correct_value");
	    }
    }

    function prove_maxMint_returns_correct_value(address receiver) public { // OK
        if(receiver != address(0)) {
            assertEq(vault.maxMint(receiver), 2**256 - 1, "maxMint_returns_correct_value");
        }
    }

    function prove_convertToShares_gte_previewDeposit(uint256 assets) public { // OK
        assert(vault.convertToShares(assets) >= vault.previewDeposit(assets));
    }

    function prove_previewMintRoundingDirection(uint256 shares) public { // OK
        if(shares > 0) {
        	uint256 tokensConsumed = vault.previewMint(shares);
        	assertGt(
            	tokensConsumed,
           	    0,
            	"previewMint() must never mint shares at no cost"
        	);
	    }
    } 

    function prove_convertToSharesRoundingDirection() public { // OK
        uint256 tokensWithdrawn = vault.convertToShares(0);
        assertEq(
            tokensWithdrawn,
            0,
            "convertToShares() must not allow shares to be minted at no cost"
        );
    }

    function prove_previewWithdrawRoundingDirection(uint256 tokens) public { // OK
        if(tokens > 0) {
	        uint256 sharesRedeemed = vault.previewWithdraw(tokens);
       		assertGt(
            		sharesRedeemed,
            		0,
            		"previewWithdraw() must not allow assets to be withdrawn at no cost"
        	);
	    }
    }

    function prove_convertRoundTrip2(uint256 amount) public { // OK
        uint256 tokensWithdrawn = vault.convertToAssets(amount);
        uint256 sharesMinted = vault.convertToShares(tokensWithdrawn);
        if(amount>=sharesMinted) assert(true);
        else assert(false);
    }

   function prove_invest_performanceFee() public { // OK
        uint256 balance = vault.convertToAssets(vault.balanceOf(treasury));
        uint256 profit = vault.totalProfit();
        assertApproxEqRel(balance, profit.mulWadDown(vault.performanceFee()), 0.015e18);
    }

    function prove_integrity_of_setStEThToEthPriceFeed(address newStEthPriceFeed) public { // OK
        if(newStEthPriceFeed != address(0x00)) {
            oracleLib.setStEThToEthPriceFeed(newStEthPriceFeed);
            assertEq(address(oracleLib.stEThToEthPriceFeed()), newStEthPriceFeed);
        }

    }

    function prove_revert_of_setStEThToEthPriceFeed() public { // OK
        try oracleLib.setStEThToEthPriceFeed(address(0x00)) {
            assert(false);
        }
        catch {
            assert(true);
        }
    }


    function prove_receiveFlashLoan_InvalidFlashLoanCaller() public { // OK
        address[] memory empty;
        uint256[] memory amounts = new uint[](1);
        amounts[0] = 1;
        try vault.receiveFlashLoan(empty, amounts, amounts, abi.encode(1)) {
            assert(false);
        }
        catch {
            assert(true);
        }
    }

/*    function prove_integrity_of_mint(uint256 shares, address receiver) public { // Not OK
        if(shares != 0 && receiver != address(0) && receiver != address(vault) && msg.sender != address(vault)) {
            uint256 _userAssets = weth.balanceOf(msg.sender);
            uint256 _totalAssets = weth.balanceOf(address(vault));
            uint256 _receiverShares = vault.balanceOf(receiver);
            //require _receiverShares + shares <= totalSupply();

            uint256 assets = vault.mint(shares, receiver);
            //require _totalAssets + assets <= asset.totalSupply();

            uint256 userAssets_ = weth.balanceOf(msg.sender);
            uint256 totalAssets_ = weth.balanceOf(address(vault));
            uint256 receiverShares_ = vault.balanceOf(receiver);

            assert(_userAssets <= userAssets_ + assets); // OK
            assert(_totalAssets + assets >= totalAssets_); // OK
            assertEq(_receiverShares + shares , receiverShares_, "Issue in receiver assets");
        }
    }

    function prove_mint_reverts_if_not_enough_assets(uint256 shares, address receiver) public { // Not OK
        if(shares != 0 && receiver != address(0) && receiver != address(vault) && msg.sender != address(vault)) {
            uint256 assets = vault.previewMint(shares);

            if(weth.balanceOf(msg.sender) < assets) {

                try vault.mint(shares, receiver) {
                    assert(false);
                }
                catch {
                    assert(true);
                }
            }
        }
    }

    function prove_integrity_of_redeem(uint256 shares, address receiver, address owner) public { // Maybe not OK
        if(msg.sender != address(vault) && receiver != address(0) && receiver != address(vault) && vault.previewRedeem(shares) != 0 && vault.allowance(owner, msg.sender) >= shares && vault.balanceOf(owner)>=shares) {
            uint256 _receiverAssets = weth.balanceOf(receiver);
            uint256 _totalAssets = weth.balanceOf(address(vault));
            uint256 _ownerShares = vault.balanceOf(owner);
            uint256 _senderAllowance = vault.allowance(owner, msg.sender);

            uint256 assets = vault.redeem(shares, receiver, owner);

            uint256 receiverAssets_ = weth.balanceOf(receiver);
            uint256 totalAssets_ = weth.balanceOf(address(vault));
            uint256 ownerShares_ = vault.balanceOf(owner);
            uint256 senderAllowance_ = vault.allowance(owner, msg.sender);

            assertEq(_totalAssets - assets, totalAssets_, "Issue in total assets"); // OK
            assertEq(_receiverAssets + assets, receiverAssets_, "Issue in received assets"); // OK
            assertEq(_ownerShares - shares, ownerShares_,"Issue in owner shares"); // OK
            assert(msg.sender != owner && ((_senderAllowance == 2**256 -1 && senderAllowance_ == 2**256 -1) || (_senderAllowance - shares == senderAllowance_))); // OK
        }
    }

    function prove_redeem_reverts_if_not_enough_shares(uint256 shares, address receiver, address owner) public { // OK
        if(vault.balanceOf(owner) < shares || msg.sender != owner && vault.allowance(owner, msg.sender) < shares)
            try vault.redeem(shares, receiver, owner) {
                assert(false);
            }
            catch {
                assert(true);
            }
    }

    function prove_previewRedeem_lte_redeem(uint256 shares, address receiver, address owner) public { // Maybe not OK
        if(msg.sender != address(vault) && receiver != address(0) && receiver != address(vault) && vault.previewRedeem(shares) != 0 && vault.allowance(owner, msg.sender) >= shares && vault.balanceOf(owner)>=shares)
            assert(vault.previewRedeem(shares) <= vault.redeem(shares, receiver, owner));
    }

    function prove_receiveFlashLoan_FailsIfInitiatorIsNotVault() public { // hevm freezes
        IVault balancer = IVault(C.BALANCER_VAULT);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        bytes memory ebytes = new bytes(2);

        tokens[0] = address(weth);
        amounts[0] = 100e18;

        try balancer.flashLoan(address(vault), tokens, amounts, ebytes) { // abi.encode(0, 0)
            assert(false);
        }
        catch {
            assert(true);
        }
    }

    function prove_withdraw_revert(uint256 anyUint, address anyAddr1, address anyAddr2) public { // OK
        try vault.withdraw(anyUint, anyAddr1, anyAddr2) {
            assert(false);
        }
        catch {
            assert(true);
        }
    }
*/
/*
    function prove_deposit_eth(uint256 amount) public { // Not OK
        if(weth.balanceOf(address(this)) == 0 && address(this).balance == amount) {

            vault.deposit{value: amount}(address(this)); // This is not fully processed by hevm

            assertEq(address(this).balance, 0, "eth not transferred from user");
            assertEq(vault.balanceOf(address(this)), amount, "shares not minted");
            assertEq(weth.balanceOf(address(vault)), amount, "weth not transferred to vault");
        }
    }

    function prove_invest_FloatBalanceTooSmall(uint256 amount) public { // Not working yet
        amount = bound(amount, boundMinimum, 15000 ether);
        _depositToVault(address(this), amount);

        uint256 investAmount = amount - minimumFloatAmount + 1;

        (scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams,,) =
            _getInvestParams(investAmount, aaveV3AllocationPercent, eulerAllocationPercent, compoundAllocationPercent);

        // deposit into strategy
        //vm.startPrank(keeper);
        //vm.expectRevert(
        //    abi.encodeWithSelector(FloatBalanceTooSmall.selector, minimumFloatAmount - 1, minimumFloatAmount)
        //);
        //vault.investAndHarvest(investAmount, supplyBorrowParams, "");
        assert(true);
    }

    function prove_convertToAssets_lte_previewMint(uint256 shares) public { // Not OK
        if(shares > 1e10)
	        assert(vault.convertToAssets(shares) <= vault.previewMint(shares));
    }

    function prove_deposit(uint256 assets, address receiver) public { // Not OK
        if(assets > 1e10 && receiver != address(0) && receiver != address(vault) && msg.sender != address(vault)) {
            uint256 _userAssets = weth.balanceOf(msg.sender);
            uint256 _totalAssets = weth.balanceOf(address(vault));
            uint256 _receiverShares = vault.balanceOf(receiver);


            uint256 shares = vault.deposit(assets, receiver);
        
            uint256 userAssets_ = weth.balanceOf(msg.sender);
            uint256 totalAssets_ = weth.balanceOf(address(vault));
            uint256 receiverShares_ = vault.balanceOf(receiver);

            assert(_userAssets <= userAssets_ + assets); // OK
            assert(_totalAssets + assets >= totalAssets_); // OK
            assertEq(_receiverShares + shares, receiverShares_, "Vault did not receive the shares"); // OK
            assertEq(vault.balanceOf(receiver), assets, "balanceOf assertion failed"); // OK
        }
    }
    function prove_deposit_reverts_if_not_enough_assets(uint256 assets, address receiver) public { // Not OK
        if(assets > 1e10 && receiver != address(0) && receiver != address(vault) && msg.sender != address(vault)) {
            uint256 userAssets = weth.balanceOf(msg.sender);
            if(userAssets < assets) {
                try vault.deposit(assets, receiver) {
                    assert(false);
                }
                catch {
                    assert(true);
                }
            }
        }
    }
*/

    //////////////////////////// INTERNAL METHODS ////////////////////////////////////////

    function _deployOracleLib() internal returns (OracleLib) {
        return new OracleLib(AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED), C.WSTETH, C.WETH, admin);
    }

    function _createDefaultWethv2VaultConstructorParams(OracleLib _oracleLib)
        internal
        returns (scWETHv2Harness.ConstructorParams memory)
    {
        return scWETHv2Harness.ConstructorParams({
            admin: admin,
            keeper: keeper,
            slippageTolerance: slippageTolerance,
            weth: WETH(payable(weth)), //C.WETH,
            balancerVault: IVault(C.BALANCER_VAULT),
            oracleLib: _oracleLib,
            wstEthToWethSwapRouter: address(new WstEthToWethSwapRouter(_oracleLib)),
            wethToWstEthSwapRouter: address(new WethToWstEthSwapRouter())
        });
    }

}
