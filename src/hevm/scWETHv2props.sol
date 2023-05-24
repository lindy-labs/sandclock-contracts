// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import {DSTestPlus} from "solmate/test/utils/DSTestPlus.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {Errors} from "aave-v3/protocol/libraries/helpers/Errors.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

import {Constants as C} from "../lib/Constants.sol";
import {scWETHv2} from "../phase-2/scWETHv2.sol";
import {LendingMarketManager} from "../phase-2/LendingMarketManager.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ILido} from "../interfaces/lido/ILido.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {sc4626} from "../sc4626.sol";
import {scWETHv2Helper} from "../phase-2/scWETHv2Helper.sol";
import {OracleLib} from "../phase-2/OracleLib.sol";
import {MockWETH} from "../../test/mocks/MockWETH.sol";
//import {WETH} from "solmate/tokens/WETH.sol";


contract scWETHv2Props is Test {
    using FixedPointMathLib for uint256;

    uint256 mainnetFork;

    address constant keeper = address(0x05);
    address constant alice = address(0x06);
    address constant treasury = address(0x07);
    uint256 boundMinimum = 1.5 ether; // below this amount, aave doesn't count it as collateral

    address admin = address(this);
    scWETHv2 vault;
    scWETHv2Helper vaultHelper;
    LendingMarketManager lendingManager;
    OracleLib oracleLib;
    uint256 initAmount = 100e18;

    uint256 aaveV3AllocationPercent = 0.5e18;
    uint256 eulerAllocationPercent = 0.3e18;
    uint256 compoundAllocationPercent = 0.2e18;

    uint256 slippageTolerance = 0.99e18;
    uint256 maxLtv;
    MockWETH weth; // (Diff 1)
    ILido stEth;
    IwstETH wstEth;
    AggregatorV3Interface public stEThToEthPriceFeed;
    uint256 minimumFloatAmount;

    mapping(LendingMarketManager.Protocol => uint256) targetLtv;

    function setUp() public {
        /*vm.createFork(vm.envString("RPC_URL_MAINNET"));
        vm.selectFork(mainnetFork);
        vm.rollFork(16784444);*/

        lendingManager = _deployLendingManagerContract();
        oracleLib = _deployOracleLib(lendingManager);
        weth = new MockWETH(); //weth = vault.weth();
        scWETHv2.ConstructorParams memory params = _createDefaultWethv2VaultConstructorParams(lendingManager, oracleLib);
        vault = new scWETHv2(params);
        vaultHelper = new scWETHv2Helper(vault, lendingManager, oracleLib);

        stEth = vault.stEth();
        wstEth = vault.wstETH();
        stEThToEthPriceFeed = AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED);
        minimumFloatAmount = vault.minimumFloatAmount();

        // set vault eth balance to zero
        //vm.deal(address(vault), 0);

        targetLtv[LendingMarketManager.Protocol.AAVE_V3] = 0.7e18;
        targetLtv[LendingMarketManager.Protocol.EULER] = 0.5e18;
        targetLtv[LendingMarketManager.Protocol.COMPOUND_V3] = 0.7e18;

        //hoax(keeper);
        //vault.approveEuler();
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

    function prove_convertToAssets_lte_previewMint(uint256 shares) public { // OK
	    assert(vault.convertToAssets(shares) <= vault.previewMint(shares));
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

    function prove_deposit(uint256 assets, address receiver) public { // OK
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

/*
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

    function prove_invest_performanceFee() public { // OK
        uint256 balance = vault.convertToAssets(vault.balanceOf(treasury));
        uint256 profit = vault.totalProfit();
        assertApproxEqRel(balance, profit.mulWadDown(vault.performanceFee()), 0.015e18);
    }

    function prove_integrity_of_mint(uint256 shares, address receiver) public { // OK
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
/*
    function prove_mint_reverts_if_not_enough_assets(uint256 shares, address receiver) public {
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
*/
    function prove_integrity_of_redeem(uint256 shares, address receiver, address owner) public { // OK
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

    function prove_previewRedeem_lte_redeem(uint256 shares, address receiver, address owner) public { // OK
        if(msg.sender != address(vault) && receiver != address(0) && receiver != address(vault) && vault.previewRedeem(shares) != 0 && vault.allowance(owner, msg.sender) >= shares && vault.balanceOf(owner)>=shares)
            assert(vault.previewRedeem(shares) <= vault.redeem(shares, receiver, owner));
    }


    function prove_integrity_of_setStEThToEthPriceFeed(address newStEthPriceFeed) public {
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
/*
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
*/
    function prove_withdraw_revert(uint256 anyUint, address anyAddr1, address anyAddr2) public { // OK
        try vault.withdraw(anyUint, anyAddr1, anyAddr2) {
            assert(false);
        }
        catch {
            assert(true);
        }
    }

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
*/
    //////////////////////////// INTERNAL METHODS ////////////////////////////////////////

    /*function _calcSupplyBorrowFlashLoanAmount(LendingMarketManager.Protocol protocol, uint256 amount)
        internal
        view
        returns (uint256 flashLoanAmount)
    {
        uint256 debt = vaultHelper.getDebt(protocol);
        uint256 collateral = vaultHelper.getCollateral(protocol);

        uint256 target = targetLtv[protocol].mulWadDown(amount + collateral);

        // calculate the flashloan amount needed
        flashLoanAmount = (target - debt).divWadDown(C.ONE - targetLtv[protocol]);
    }

    function _calcRepayWithdrawFlashLoanAmount(LendingMarketManager.Protocol protocol, uint256 amount, uint256 ltv)
        internal
        view
        returns (uint256 flashLoanAmount)
    {
        uint256 debt = vaultHelper.getDebt(protocol);
        uint256 collateral = vaultHelper.getCollateral(protocol);

        uint256 target = ltv.mulWadDown(amount + collateral);

        // calculate the flashloan amount needed
        flashLoanAmount = (debt - target).divWadDown(C.ONE - ltv);
    }

    // market1 is the protocol we withdraw assets from
    // and market2 is the protocol we supply those assets to
    function _getReallocationParamsWhenMarket1HasHigherLtv(
        uint256 reallocationAmount,
        uint256 market1Assets,
        uint256 market2Ltv
    ) internal view returns (scWETHv2.RepayWithdrawParam[] memory, scWETHv2.SupplyBorrowParam[] memory, uint256) {
        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParamsReallocation = new scWETHv2.RepayWithdrawParam[](1);
        scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsReallocation = new scWETHv2.SupplyBorrowParam[](1);

        uint256 repayAmount =
            reallocationAmount.mulDivDown(vaultHelper.getDebt(LendingMarketManager.Protocol.AAVE_V3), market1Assets);
        uint256 withdrawAmount = reallocationAmount + repayAmount;

        repayWithdrawParamsReallocation[0] = scWETHv2.RepayWithdrawParam(
            LendingMarketManager.Protocol.AAVE_V3, repayAmount, oracleLib.ethToWstEth(withdrawAmount)
        );

        // since the ltv of the second protocol euler is less than the first protocol aaveV3
        // we cannot supply the withdraw amount and borrow the repay Amount since that will increase the ltv of euler
        uint256 delta = (repayAmount - market2Ltv.mulWadDown(withdrawAmount)).divWadDown(1e18 - market2Ltv);
        uint256 market2SupplyAmount = withdrawAmount - delta;
        uint256 market2BorrowAmount = repayAmount - delta;

        supplyBorrowParamsReallocation[0] = scWETHv2.SupplyBorrowParam(
            LendingMarketManager.Protocol.EULER, oracleLib.ethToWstEth(market2SupplyAmount), market2BorrowAmount
        );

        return (repayWithdrawParamsReallocation, supplyBorrowParamsReallocation, delta);
    }

    function _getReallocationParamsWhenMarket1HasLowerLtv(
        uint256 reallocationAmount,
        uint256 market1Assets,
        uint256 market2Ltv
    ) internal view returns (scWETHv2.RepayWithdrawParam[] memory, scWETHv2.SupplyBorrowParam[] memory, uint256) {
        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParamsReallocation = new scWETHv2.RepayWithdrawParam[](1);
        scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsReallocation = new scWETHv2.SupplyBorrowParam[](1);

        uint256 repayAmount =
            reallocationAmount.mulDivDown(vaultHelper.getDebt(LendingMarketManager.Protocol.EULER), market1Assets);
        uint256 withdrawAmount = reallocationAmount + repayAmount;

        repayWithdrawParamsReallocation[0] = scWETHv2.RepayWithdrawParam(
            LendingMarketManager.Protocol.EULER, repayAmount, oracleLib.ethToWstEth(withdrawAmount)
        );

        uint256 market2SupplyAmount = repayAmount.divWadDown(market2Ltv);
        uint256 market2BorrowAmount = repayAmount;

        uint256 delta = withdrawAmount - market2SupplyAmount;

        supplyBorrowParamsReallocation[0] = scWETHv2.SupplyBorrowParam(
            LendingMarketManager.Protocol.AAVE_V3, oracleLib.ethToWstEth(market2SupplyAmount), market2BorrowAmount
        );

        return (repayWithdrawParamsReallocation, supplyBorrowParamsReallocation, delta);
    }

    function _getReallocationParamsFromOneMarketToTwoMarkets(uint256 reallocationAmount)
        internal
        view
        returns (scWETHv2.RepayWithdrawParam[] memory, scWETHv2.SupplyBorrowParam[] memory, uint256)
    {
        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParamsReallocation = new scWETHv2.RepayWithdrawParam[](1);
        scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsReallocation = new scWETHv2.SupplyBorrowParam[](2);

        uint256 repayAmount = reallocationAmount.mulDivDown(
            vaultHelper.getDebt(LendingMarketManager.Protocol.EULER),
            vaultHelper.getAssets(LendingMarketManager.Protocol.EULER)
        );
        uint256 withdrawAmount = reallocationAmount + repayAmount;

        repayWithdrawParamsReallocation[0] = scWETHv2.RepayWithdrawParam(
            LendingMarketManager.Protocol.EULER, repayAmount, oracleLib.ethToWstEth(withdrawAmount)
        );

        // supply 50% of the reallocationAmount to aaveV3 and 50% to compoundV3
        // we are using the below style of calculating since aaveV3 and compoundV3 both have higher ltv than euler
        uint256 aaveV3SupplyAmount =
            (repayAmount / 2).divWadDown(vaultHelper.getLtv(LendingMarketManager.Protocol.AAVE_V3));
        uint256 aaveV3BorrowAmount = (repayAmount / 2);

        uint256 compoundSupplyAmount =
            (repayAmount / 2).divWadDown(vaultHelper.getLtv(LendingMarketManager.Protocol.COMPOUND_V3));
        uint256 compoundBorrowAmount = (repayAmount / 2);

        uint256 delta = withdrawAmount - (aaveV3SupplyAmount + compoundSupplyAmount);

        supplyBorrowParamsReallocation[0] = scWETHv2.SupplyBorrowParam({
            protocol: LendingMarketManager.Protocol.AAVE_V3,
            supplyAmount: oracleLib.ethToWstEth(aaveV3SupplyAmount),
            borrowAmount: aaveV3BorrowAmount
        });

        supplyBorrowParamsReallocation[1] = scWETHv2.SupplyBorrowParam({
            protocol: LendingMarketManager.Protocol.COMPOUND_V3,
            supplyAmount: oracleLib.ethToWstEth(compoundSupplyAmount),
            borrowAmount: compoundBorrowAmount
        });

        return (repayWithdrawParamsReallocation, supplyBorrowParamsReallocation, delta);
    }

    function _getReallocationParamsFromTwoMarketsToOneMarket(uint256 reallocationAmount)
        internal
        view
        returns (scWETHv2.RepayWithdrawParam[] memory, scWETHv2.SupplyBorrowParam[] memory, uint256)
    {
        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParamsReallocation = new scWETHv2.RepayWithdrawParam[](2);
        scWETHv2.SupplyBorrowParam[] memory supplyBorrowParamsReallocation = new scWETHv2.SupplyBorrowParam[](1);

        // we will withdraw 50% of the reallocation amount from aaveV3 and the other 50% from compoundV3
        uint256 reallocationAmountPerMarket = reallocationAmount / 2;

        uint256 repayAmountAaveV3 = reallocationAmountPerMarket.mulDivDown(
            vaultHelper.getDebt(LendingMarketManager.Protocol.AAVE_V3),
            vaultHelper.getAssets(LendingMarketManager.Protocol.AAVE_V3)
        );
        uint256 withdrawAmountAaveV3 = reallocationAmountPerMarket + repayAmountAaveV3;

        uint256 repayAmountCompoundV3 = reallocationAmountPerMarket.mulDivDown(
            vaultHelper.getDebt(LendingMarketManager.Protocol.COMPOUND_V3),
            vaultHelper.getAssets(LendingMarketManager.Protocol.COMPOUND_V3)
        );
        uint256 withdrawAmountCompoundV3 = reallocationAmountPerMarket + repayAmountCompoundV3;

        repayWithdrawParamsReallocation[0] = scWETHv2.RepayWithdrawParam(
            LendingMarketManager.Protocol.AAVE_V3, repayAmountAaveV3, oracleLib.ethToWstEth(withdrawAmountAaveV3)
        );

        repayWithdrawParamsReallocation[1] = scWETHv2.RepayWithdrawParam(
            LendingMarketManager.Protocol.COMPOUND_V3,
            repayAmountCompoundV3,
            oracleLib.ethToWstEth(withdrawAmountCompoundV3)
        );

        uint256 repayAmount = repayAmountAaveV3 + repayAmountCompoundV3;
        uint256 withdrawAmount = withdrawAmountAaveV3 + withdrawAmountCompoundV3;
        uint256 eulerLtv = vaultHelper.getLtv(LendingMarketManager.Protocol.EULER);

        uint256 delta = (repayAmount - eulerLtv.mulWadDown(withdrawAmount)).divWadDown(1e18 - eulerLtv);
        uint256 eulerSupplyAmount = withdrawAmount - delta;
        uint256 eulerBorrowAmount = repayAmount - delta;

        supplyBorrowParamsReallocation[0] = scWETHv2.SupplyBorrowParam(
            LendingMarketManager.Protocol.EULER, oracleLib.ethToWstEth(eulerSupplyAmount), eulerBorrowAmount
        );

        return (repayWithdrawParamsReallocation, supplyBorrowParamsReallocation, delta);
    }

    /// @return : supplyBorrowParams, totalSupplyAmount, totalDebtTaken
    function _getInvestParams(
        uint256 amount,
        uint256 aaveV3Allocation,
        uint256 eulerAllocation,
        uint256 compoundAllocation
    ) internal view returns (scWETHv2.SupplyBorrowParam[] memory, uint256, uint256) {
        uint256 stEthRateTolerance = 0.999e18;
        scWETHv2.SupplyBorrowParam[] memory supplyBorrowParams = new scWETHv2.SupplyBorrowParam[](3);

        // supply 70% to aaveV3 and 30% to Euler
        uint256 aaveV3Amount = amount.mulWadDown(aaveV3Allocation);
        uint256 eulerAmount = amount.mulWadDown(eulerAllocation);
        uint256 compoundAmount = amount.mulWadDown(compoundAllocation);

        uint256 aaveV3FlashLoanAmount =
            _calcSupplyBorrowFlashLoanAmount(LendingMarketManager.Protocol.AAVE_V3, aaveV3Amount);
        uint256 eulerFlashLoanAmount =
            _calcSupplyBorrowFlashLoanAmount(LendingMarketManager.Protocol.EULER, eulerAmount);
        uint256 compoundFlashLoanAmount =
            _calcSupplyBorrowFlashLoanAmount(LendingMarketManager.Protocol.COMPOUND_V3, compoundAmount);

        uint256 aaveV3SupplyAmount =
            oracleLib.ethToWstEth(aaveV3Amount + aaveV3FlashLoanAmount).mulWadDown(stEthRateTolerance);
        uint256 eulerSupplyAmount =
            oracleLib.ethToWstEth(eulerAmount + eulerFlashLoanAmount).mulWadDown(stEthRateTolerance);
        uint256 compoundSupplyAmount =
            oracleLib.ethToWstEth(compoundAmount + compoundFlashLoanAmount).mulWadDown(stEthRateTolerance);

        supplyBorrowParams[0] = scWETHv2.SupplyBorrowParam({
            protocol: LendingMarketManager.Protocol.AAVE_V3,
            supplyAmount: aaveV3SupplyAmount,
            borrowAmount: aaveV3FlashLoanAmount
        });
        supplyBorrowParams[1] = scWETHv2.SupplyBorrowParam({
            protocol: LendingMarketManager.Protocol.EULER,
            supplyAmount: eulerSupplyAmount,
            borrowAmount: eulerFlashLoanAmount
        });
        supplyBorrowParams[2] = scWETHv2.SupplyBorrowParam({
            protocol: LendingMarketManager.Protocol.COMPOUND_V3,
            supplyAmount: compoundSupplyAmount,
            borrowAmount: compoundFlashLoanAmount
        });

        uint256 totalSupplyAmount = aaveV3SupplyAmount + eulerSupplyAmount + compoundSupplyAmount;
        uint256 totalDebtTaken = aaveV3FlashLoanAmount + eulerFlashLoanAmount + compoundFlashLoanAmount;

        return (supplyBorrowParams, totalSupplyAmount, totalDebtTaken);
    }

    /// @return : repayWithdrawParams
    function _getDisInvestParams(uint256 newAaveV3Ltv, uint256 newEulerLtv, uint256 newCompoundLtv)
        internal
        view
        returns (scWETHv2.RepayWithdrawParam[] memory)
    {
        uint256 aaveV3FlashLoanAmount =
            _calcRepayWithdrawFlashLoanAmount(LendingMarketManager.Protocol.AAVE_V3, 0, newAaveV3Ltv);
        uint256 eulerFlashLoanAmount =
            _calcRepayWithdrawFlashLoanAmount(LendingMarketManager.Protocol.EULER, 0, newEulerLtv);
        uint256 compoundFlashLoanAmount =
            _calcRepayWithdrawFlashLoanAmount(LendingMarketManager.Protocol.COMPOUND_V3, 0, newCompoundLtv);

        scWETHv2.RepayWithdrawParam[] memory repayWithdrawParams = new scWETHv2.RepayWithdrawParam[](3);

        repayWithdrawParams[0] = scWETHv2.RepayWithdrawParam(
            LendingMarketManager.Protocol.AAVE_V3, aaveV3FlashLoanAmount, oracleLib.ethToWstEth(aaveV3FlashLoanAmount)
        );

        repayWithdrawParams[1] = scWETHv2.RepayWithdrawParam(
            LendingMarketManager.Protocol.EULER, eulerFlashLoanAmount, oracleLib.ethToWstEth(eulerFlashLoanAmount)
        );

        repayWithdrawParams[2] = scWETHv2.RepayWithdrawParam(
            LendingMarketManager.Protocol.COMPOUND_V3,
            compoundFlashLoanAmount,
            oracleLib.ethToWstEth(compoundFlashLoanAmount)
        );

        return repayWithdrawParams;
    }

    function _depositChecks(uint256 amount, uint256 preDepositBal) internal {
        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18, "convertToAssets decimal assertion failed");
        assertEq(vault.totalAssets(), amount, "totalAssets assertion failed");
        assertEq(vault.balanceOf(address(this)), amount, "balanceOf assertion failed");
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), amount, "convertToAssets assertion failed");
        assertEq(weth.balanceOf(address(this)), preDepositBal - amount, "weth balance assertion failed");
    }

    function _redeemChecks(uint256 preDepositBal) internal {
        assertEq(vault.convertToAssets(10 ** vault.decimals()), 1e18);
        assertEq(vault.totalAssets(), 0);
        assertEq(vault.balanceOf(address(this)), 0);
        assertEq(vault.convertToAssets(vault.balanceOf(address(this))), 0);
        assertEq(weth.balanceOf(address(this)), preDepositBal);
    }

    function _investChecks(uint256 amount, uint256 totalSupplyAmount, uint256 totalDebtTaken) internal {
        uint256 totalCollateral = vault.totalCollateral();
        uint256 totalDebt = vault.totalDebt();
        assertApproxEqRel(totalCollateral - totalDebt, amount, 0.01e18, "totalAssets not equal amount");
        assertEq(vault.totalInvested(), amount, "totalInvested not updated");
        assertApproxEqRel(totalCollateral, totalSupplyAmount, 0.0001e18, "totalCollateral not equal totalSupplyAmount");
        assertApproxEqRel(totalDebt, totalDebtTaken, 100, "totalDebt not equal totalDebtTaken");

        uint256 aaveV3Deposited = vaultHelper.getCollateral(LendingMarketManager.Protocol.AAVE_V3)
            - vaultHelper.getDebt(LendingMarketManager.Protocol.AAVE_V3);
        uint256 eulerDeposited = vaultHelper.getCollateral(LendingMarketManager.Protocol.EULER)
            - vaultHelper.getDebt(LendingMarketManager.Protocol.EULER);
        uint256 compoundDeposited = vaultHelper.getCollateral(LendingMarketManager.Protocol.COMPOUND_V3)
            - vaultHelper.getDebt(LendingMarketManager.Protocol.COMPOUND_V3);

        assertApproxEqRel(
            aaveV3Deposited, amount.mulWadDown(aaveV3AllocationPercent), 0.005e18, "aaveV3 allocation not correct"
        );
        assertApproxEqRel(
            eulerDeposited, amount.mulWadDown(eulerAllocationPercent), 0.005e18, "euler allocation not correct"
        );
        assertApproxEqRel(
            compoundDeposited, amount.mulWadDown(compoundAllocationPercent), 0.005e18, "compound allocation not correct"
        );

        assertApproxEqRel(
            vaultHelper.allocationPercent(LendingMarketManager.Protocol.AAVE_V3),
            aaveV3AllocationPercent,
            0.005e18,
            "aaveV3 allocationPercent not correct"
        );

        assertApproxEqRel(
            vaultHelper.allocationPercent(LendingMarketManager.Protocol.EULER),
            eulerAllocationPercent,
            0.005e18,
            "euler allocationPercent not correct"
        );

        assertApproxEqRel(
            vaultHelper.allocationPercent(LendingMarketManager.Protocol.COMPOUND_V3),
            compoundAllocationPercent,
            0.005e18,
            "compound allocationPercent not correct"
        );

        assertApproxEqRel(
            vaultHelper.getLtv(LendingMarketManager.Protocol.AAVE_V3),
            targetLtv[LendingMarketManager.Protocol.AAVE_V3],
            0.005e18,
            "aaveV3 ltv not correct"
        );
        assertApproxEqRel(
            vaultHelper.getLtv(LendingMarketManager.Protocol.EULER),
            targetLtv[LendingMarketManager.Protocol.EULER],
            0.005e18,
            "euler ltv not correct"
        );

        assertApproxEqRel(
            vaultHelper.getLtv(LendingMarketManager.Protocol.COMPOUND_V3),
            targetLtv[LendingMarketManager.Protocol.COMPOUND_V3],
            0.005e18,
            "compound ltv not correct"
        );
    }

    function _reallocationChecksWhenMarket1HasHigherLtv(
        uint256 totalAssets,
        uint256 inititalAaveV3Allocation,
        uint256 initialEulerAllocation,
        uint256 inititalAaveV3Assets,
        uint256 initialEulerAssets,
        uint256 initialAaveV3Ltv,
        uint256 initialEulerLtv,
        uint256 reallocationAmount
    ) internal {
        assertApproxEqRel(
            vaultHelper.allocationPercent(LendingMarketManager.Protocol.AAVE_V3),
            inititalAaveV3Allocation - 0.1e18,
            0.005e18,
            "aavev3 allocation error"
        );

        assertApproxEqRel(
            vaultHelper.allocationPercent(LendingMarketManager.Protocol.EULER),
            initialEulerAllocation + 0.1e18,
            0.005e18,
            "euler allocation error"
        );

        // assets must decrease by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(LendingMarketManager.Protocol.AAVE_V3),
            inititalAaveV3Assets - reallocationAmount,
            0.001e18,
            "aavev3 assets not decreased"
        );

        // assets must increase by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(LendingMarketManager.Protocol.EULER),
            initialEulerAssets + reallocationAmount,
            0.001e18,
            "euler assets not increased"
        );

        // totalAssets must not change
        assertApproxEqRel(vault.totalAssets(), totalAssets, 0.001e18, "total assets must not change");

        // ltvs must not change
        assertApproxEqRel(
            vaultHelper.getLtv(LendingMarketManager.Protocol.AAVE_V3),
            initialAaveV3Ltv,
            0.001e18,
            "aavev3 ltv must not change"
        );

        assertApproxEqRel(
            vaultHelper.getLtv(LendingMarketManager.Protocol.EULER),
            initialEulerLtv,
            0.001e18,
            "euler ltv must not change"
        );
    }

    function _reallocationChecksWhenMarket1HasLowerLtv(
        uint256 totalAssets,
        uint256 inititalAaveV3Assets,
        uint256 initialEulerAssets,
        uint256 initialAaveV3Ltv,
        uint256 initialEulerLtv,
        uint256 reallocationAmount
    ) internal {
        // note: after reallocating from a lower ltv protocol to a higher ltv protocol
        // there is some float remaining in the contract due to the difference in ltv
        uint256 float = weth.balanceOf(address(vault));

        // assets must increase by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(LendingMarketManager.Protocol.AAVE_V3) + float - minimumFloatAmount,
            inititalAaveV3Assets + reallocationAmount,
            0.001e18,
            "aavev3 assets not increased"
        );

        // assets must decrease by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(LendingMarketManager.Protocol.EULER),
            initialEulerAssets - reallocationAmount,
            0.001e18,
            "euler assets not decreased"
        );

        // totalAssets must not change
        assertApproxEqRel(vault.totalAssets(), totalAssets, 0.001e18, "total assets must not change");

        // ltvs must not change
        assertApproxEqRel(
            vaultHelper.getLtv(LendingMarketManager.Protocol.AAVE_V3),
            initialAaveV3Ltv,
            0.001e18,
            "aavev3 ltv must not change"
        );

        assertApproxEqRel(
            vaultHelper.getLtv(LendingMarketManager.Protocol.EULER),
            initialEulerLtv,
            0.001e18,
            "euler ltv must not change"
        );
    }

    function _reallocationChecksFromOneMarketToTwoMarkets(
        uint256 totalAssets,
        uint256 inititalAaveV3Assets,
        uint256 initialEulerAssets,
        uint256 initialCompoundAssets,
        uint256 initialAaveV3Ltv,
        uint256 initialEulerLtv,
        uint256 initialCompoundLtv,
        uint256 reallocationAmount
    ) internal {
        // note: after reallocating from a lower ltv protocol to a higher ltv market
        // there is some float remaining in the contract due to the difference in ltv
        uint256 float = weth.balanceOf(address(vault));

        // assets must increase by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(LendingMarketManager.Protocol.AAVE_V3)
                + vaultHelper.getAssets(LendingMarketManager.Protocol.COMPOUND_V3) + float - minimumFloatAmount,
            inititalAaveV3Assets + initialCompoundAssets + reallocationAmount,
            0.001e18,
            "aavev3 & compound assets not increased"
        );

        // assets must decrease by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(LendingMarketManager.Protocol.EULER),
            initialEulerAssets - reallocationAmount,
            0.001e18,
            "euler assets not decreased"
        );

        // totalAssets must not change
        assertApproxEqRel(vault.totalAssets(), totalAssets, 0.001e18, "total assets must not change");

        // ltvs must not change
        assertApproxEqRel(
            vaultHelper.getLtv(LendingMarketManager.Protocol.AAVE_V3),
            initialAaveV3Ltv,
            0.001e18,
            "aavev3 ltv must not change"
        );

        assertApproxEqRel(
            vaultHelper.getLtv(LendingMarketManager.Protocol.EULER),
            initialEulerLtv,
            0.001e18,
            "euler ltv must not change"
        );

        assertApproxEqRel(
            vaultHelper.getLtv(LendingMarketManager.Protocol.COMPOUND_V3),
            initialCompoundLtv,
            0.001e18,
            "compound ltv must not change"
        );
    }

    function _reallocationChecksFromTwoMarkets_TwoOneMarket(
        uint256 totalAssets,
        uint256 inititalAaveV3Assets,
        uint256 initialEulerAssets,
        uint256 initialCompoundAssets,
        uint256 initialAaveV3Ltv,
        uint256 initialEulerLtv,
        uint256 initialCompoundLtv,
        uint256 reallocationAmount
    ) internal {
        assertApproxEqRel(
            vaultHelper.allocationPercent(LendingMarketManager.Protocol.AAVE_V3)
                + vaultHelper.allocationPercent(LendingMarketManager.Protocol.COMPOUND_V3),
            aaveV3AllocationPercent + compoundAllocationPercent - 0.1e18,
            0.005e18,
            "aavev3 & compound allocation error"
        );

        assertApproxEqRel(
            vaultHelper.allocationPercent(LendingMarketManager.Protocol.EULER),
            eulerAllocationPercent + 0.1e18,
            0.005e18,
            "euler allocation error"
        );

        // assets must decrease by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(LendingMarketManager.Protocol.AAVE_V3)
                + vaultHelper.getAssets(LendingMarketManager.Protocol.COMPOUND_V3),
            inititalAaveV3Assets + initialCompoundAssets - reallocationAmount,
            0.001e18,
            "aavev3 & compound assets not decreased"
        );

        // assets must increase by reallocationAmount
        assertApproxEqRel(
            vaultHelper.getAssets(LendingMarketManager.Protocol.EULER),
            initialEulerAssets + reallocationAmount,
            0.001e18,
            "euler assets not increased"
        );

        // totalAssets must not change
        assertApproxEqRel(vault.totalAssets(), totalAssets, 0.001e18, "total assets must not change");

        // ltvs must not change
        assertApproxEqRel(
            vaultHelper.getLtv(LendingMarketManager.Protocol.AAVE_V3),
            initialAaveV3Ltv,
            0.001e18,
            "aavev3 ltv must not change"
        );

        assertApproxEqRel(
            vaultHelper.getLtv(LendingMarketManager.Protocol.EULER),
            initialEulerLtv,
            0.001e18,
            "euler ltv must not change"
        );

        assertApproxEqRel(
            vaultHelper.getLtv(LendingMarketManager.Protocol.COMPOUND_V3),
            initialCompoundLtv,
            0.001e18,
            "compound ltv must not change"
        );
    }

    function _floatCheck() internal {
        assertGe(weth.balanceOf(address(vault)), minimumFloatAmount, "float not maintained");
    }

    function _depositToVault(address user, uint256 amount) internal returns (uint256 shares) {
        //deal(address(weth), user, amount);
        //vm.startPrank(user);
        weth.approve(address(vault), amount);
        shares = vault.deposit(amount, user);
        //vm.stopPrank();
    }
*/
    function _deployOracleLib(LendingMarketManager _lendingManager) internal returns (OracleLib) {
        return
        new OracleLib(AggregatorV3Interface(C.CHAINLINK_STETH_ETH_PRICE_FEED),_lendingManager, C.WSTETH, C.WETH, admin);
    }

    function _deployLendingManagerContract() internal returns (LendingMarketManager) {
        LendingMarketManager.AaveV3 memory aaveV3 = LendingMarketManager.AaveV3({
            pool: C.AAVE_POOL,
            aWstEth: C.AAVE_AWSTETH_TOKEN,
            varDWeth: C.AAVAAVE_VAR_DEBT_WETH_TOKEN
        });

        LendingMarketManager.Euler memory euler = LendingMarketManager.Euler({
            protocol: C.EULER,
            markets: C.EULER_MARKETS,
            eWstEth: C.EULER_ETOKEN_WSTETH,
            dWeth: C.EULER_DTOKEN_WETH
        });

        LendingMarketManager.Compound memory compound = LendingMarketManager.Compound({comet: C.COMPOUND_V3_COMET_WETH});

        return new LendingMarketManager(C.STETH, C.WSTETH, C.WETH, aaveV3, euler, compound);
    }

    function _createDefaultWethv2VaultConstructorParams(LendingMarketManager _lendingManager, OracleLib _oracleLib)
        internal
        view
        returns (scWETHv2.ConstructorParams memory)
    {
        return scWETHv2.ConstructorParams({
            admin: admin,
            keeper: keeper,
            slippageTolerance: slippageTolerance,
            stEth: C.STETH,
            wstEth: C.WSTETH,
            weth: WETH(payable(weth)), //,C.WETH, //
            curvePool: ICurvePool(C.CURVE_ETH_STETH_POOL),
            balancerVault: IVault(C.BALANCER_VAULT),
            lendingManager: _lendingManager,
            oracleLib: _oracleLib
        });
    }
/*
    function _simulate_stEthStakingInterest(uint256 timePeriod, uint256 stEthStakingInterest) internal {
        // fast forward time to simulate supply and borrow interests
        vm.warp(block.timestamp + timePeriod);
        uint256 prevBalance = read_storage_uint(address(stEth), keccak256(abi.encodePacked("lido.Lido.beaconBalance")));
        vm.store(
            address(stEth),
            keccak256(abi.encodePacked("lido.Lido.beaconBalance")),
            bytes32(prevBalance.mulWadDown(stEthStakingInterest))
        );
    }

    function read_storage_uint(address addr, bytes32 key) internal view returns (uint256) {
        return abi.decode(abi.encode(vm.load(addr, key)), (uint256));
    }

    receive() external payable {}*/
}
