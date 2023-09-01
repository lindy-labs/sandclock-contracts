// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import "forge-std/Test.sol";
import "forge-std/Script.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Surl} from "surl/Surl.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {Constants as C} from "../../../src/lib/Constants.sol";
import {MainnetAddresses as MA} from "../../base/MainnetAddresses.sol";
import {ISwapRouter} from "../../../src/interfaces/uniswap/ISwapRouter.sol";
import {sc4626} from "../../../src/sc4626.sol";
import {scWETHv2} from "../../../src/steth/scWETHv2.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {Swapper} from "../../../src/steth/Swapper.sol";
import {PriceConverter} from "../../../src/steth/PriceConverter.sol";
import {AaveV3ScWethAdapter as scWethAaveV3Adapter} from "../../../src/steth/scWethV2-adapters/AaveV3ScWethAdapter.sol";
import {CompoundV3ScWethAdapter as scWethCompoundV3Adapter} from
    "../../../src/steth/scWethV2-adapters/CompoundV3ScWethAdapter.sol";
import {AaveV3ScUsdcAdapter as scUsdcAaveV3Adapter} from "../../../src/steth/scUsdcV2-adapters/AaveV3ScUsdcAdapter.sol";
import {AaveV2ScUsdcAdapter as scUsdcAaveV2Adapter} from "../../../src/steth/scUsdcV2-adapters/AaveV2ScUsdcAdapter.sol";
import {MainnetDeployBase} from "../../base/MainnetDeployBase.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";
import {scWETHv2Helper} from "../../../test/helpers/scWETHv2Helper.sol";
import {BaseV2Vault} from "../../../src/steth/BaseV2Vault.sol";

/**
 * invests underlying float in the vault
 * and at the same time also reinvests profits made till now by the vault
 *
 * cmd
 * first run a local anvil node using " anvil -f YOUR_RPC_URL"
 * Then run the script using
 * forge script script/v2/manual-runs/scWETHv2Rebalance.s.sol --rpc-url http://127.0.0.1:8545 --ffi
 */
contract scWETHv2Rebalance is Script, scWETHv2Helper {
    using FixedPointMathLib for uint256;
    using Surl for *;
    using Strings for *;
    using stdJson for string;

    ////////////////////////// BUTTONS ///////////////////////////////
    uint256 public MORPHO_ALLOCATION_PERCENT = 0.4e18;
    uint256 public MORPHO_TARGET_LTV = 0.8e18;

    uint256 public COMPOUNDV3_ALLOCATION_PERCENT = 0.6e18;
    uint256 public COMPOUNDV3_TARGET_LTV = 0.8e18;

    uint256 public AAVEV3_ALLOCATION_PERCENT = 0;
    uint256 public AAVEV3_TARGET_LTV = 0.8e18;

    // if the ltv overshoots the target ltv by this threshold, disinvest
    uint256 public disinvestThreshold = 0.005e18; // 0.5 %

    // be it weth gained from profits or float amount lying in the vault
    // the contract rebalance method won't be called if the minimum amount to invest is less than this threshold
    uint256 public minimumInvestAmount = 0.1 ether;
    ///////////////////////////////////////////////////////////////////////

    uint256 keeperPrivateKey = uint256(vm.envOr("KEEPER_PRIVATE_KEY", bytes32(0x00)));

    WETH weth = WETH(payable(C.WETH));

    IAdapter public morphoAdapter = IAdapter(MA.SCWETHV2_MORPHO_ADAPTER);
    IAdapter public compoundV3Adapter = IAdapter(MA.SCWETHV2_COMPOUND_ADAPTER);
    IAdapter public aaveV3Adapter = IAdapter(MA.SCWETHV2_AAVEV3_ADAPTER);

    mapping(IAdapter => uint256) public targetLtv;

    IAdapter[] adaptersToInvest;
    uint256[] allocationPercents;
    IAdapter[] adaptersToDisinvest;

    constructor() scWETHv2Helper(scWETHv2(payable(MA.SCWETHV2)), PriceConverter(MA.PRICE_CONVERTER)) {
        _initializeAdapters();
    }

    function run() external {
        address keeper = keeperPrivateKey != 0 ? vm.addr(keeperPrivateKey) : MA.KEEPER;

        vm.startBroadcast(keeper);

        // disinvest if the ltv has overshoot from target on any protocol
        _disinvest();

        _invest();

        // _logs();

        vm.stopBroadcast();
    }

    //////////////////////////////// REBALANCE /////////////////////////////////////////////
    function _rebalance() internal {}

    function _getRebalanceParams() internal returns (bytes[] memory, uint256) {}

    /// @notice returns the amount to flashloan for an adapter
    /// @dev doesn't matter if the vault has to supply/borrow or repay/withdraw
    /// @dev this supports both scenarios
    function _calcRebalanceFlashLoanAmount(IAdapter _adapter, uint256 _amount)
        internal
        view
        returns (uint256 flashLoanAmount, bool isSupplyBorrow)
    {
        uint256 debt = vault.getDebt(_adapter.id());
        uint256 collateral = getCollateralInWeth(_adapter);

        uint256 target = targetLtv[_adapter].mulWadDown(_amount + collateral);

        isSupplyBorrow = target > debt;

        // calculate the flashloan amount needed
        flashLoanAmount = (isSupplyBorrow ? target - debt : debt - target).divWadDown(C.ONE - targetLtv[_adapter]);
    }

    //////////////////////////////// INVEST /////////////////////////////////////////////
    function _initializeAdapters() internal {
        uint256 totalAllocationPercent;

        if (MORPHO_ALLOCATION_PERCENT > 0) {
            adaptersToInvest.push(morphoAdapter);
            allocationPercents.push(MORPHO_ALLOCATION_PERCENT);
            targetLtv[morphoAdapter] = MORPHO_TARGET_LTV;

            totalAllocationPercent += MORPHO_ALLOCATION_PERCENT;
        }

        if (AAVEV3_ALLOCATION_PERCENT > 0) {
            adaptersToInvest.push(aaveV3Adapter);
            allocationPercents.push(AAVEV3_ALLOCATION_PERCENT);
            targetLtv[aaveV3Adapter] = AAVEV3_TARGET_LTV;

            totalAllocationPercent += AAVEV3_ALLOCATION_PERCENT;
        }

        if (COMPOUNDV3_ALLOCATION_PERCENT > 0) {
            adaptersToInvest.push(compoundV3Adapter);
            allocationPercents.push(COMPOUNDV3_ALLOCATION_PERCENT);
            targetLtv[compoundV3Adapter] = COMPOUNDV3_TARGET_LTV;

            totalAllocationPercent += COMPOUNDV3_ALLOCATION_PERCENT;
        }

        require(totalAllocationPercent == 1e18, "totalAllocationPercent != 100%");
    }

    /// @notice invest the float lying in the vault to morpho and compoundV3
    /// @dev also reinvests profits made,i.e increases the ltv
    /// @dev if there is no undelying float in the contract, run this method to just reinvest profits
    function _invest() internal {
        uint256 float = weth.balanceOf(address(vault));
        uint256 minimumFloat = vault.minimumFloatAmount();

        // investAmount == 0 just reinvests profits
        uint256 investAmount = float > minimumFloat ? float - minimumFloat : 0;

        console2.log("\nInvesting %s weth", investAmount);

        (bytes[] memory callData, uint256 totalFlashLoanAmount) = _getInvestParams(investAmount);

        // invest or reinvest only if it the leveraged amount is greater than a certain threshold
        // to save unecessary gas fees in small rebalances
        if (totalFlashLoanAmount > minimumInvestAmount.mulWadDown(getLeverage())) {
            console2.log("---- Running invest ----");
            vault.rebalance(investAmount, totalFlashLoanAmount, callData);
        }
    }

    // returns callData, totalFlashLoanAmount
    /// @notice Returns the required calldata for investing float or reinvesting profits given the adapters to invest to and their respective allocationPercent
    /// @dev : NOTE: ASSUMING ZERO BALANCER FLASH LOAN FEES
    function _getInvestParams(uint256 _amount) internal returns (bytes[] memory, uint256) {
        uint256 stEthRateTolerance = 0.9995e18;
        uint256 n = adaptersToInvest.length;

        uint256[] memory flashLoanAmounts = new uint[](n);
        uint256[] memory supplyAmounts = new uint[](n);

        uint256 totalFlashLoanAmount;

        for (uint256 i; i < n; i++) {
            uint256 adapterInvestAmount = _amount.mulWadDown(allocationPercents[i]); // amount to be invested in this adapter
            flashLoanAmounts[i] = _calcSupplyBorrowFlashLoanAmount(adaptersToInvest[i], adapterInvestAmount);
            supplyAmounts[i] =
                priceConverter.ethToWstEth(adapterInvestAmount + flashLoanAmounts[i]).mulWadDown(stEthRateTolerance);

            totalFlashLoanAmount += flashLoanAmounts[i];
        }

        bytes[] memory callData = new bytes[](n+1);

        uint256 wethSwapAmount = _amount + totalFlashLoanAmount;
        bytes memory swapData = getSwapData(wethSwapAmount, C.WETH, C.WSTETH);

        if (swapData.length > 0) {
            callData[0] =
                abi.encodeWithSelector(BaseV2Vault.zeroExSwap.selector, C.WETH, C.WSTETH, wethSwapAmount, swapData, 0);
        } else {
            callData[0] = abi.encodeWithSelector(scWETHv2.swapWethToWstEth.selector, wethSwapAmount);
        }

        for (uint256 i = 1; i < n + 1; i++) {
            callData[i] = abi.encodeWithSelector(
                scWETHv2.supplyAndBorrow.selector,
                adaptersToInvest[i - 1].id(),
                supplyAmounts[i - 1],
                flashLoanAmounts[i - 1]
            );
        }

        return (callData, totalFlashLoanAmount);
    }

    function _calcSupplyBorrowFlashLoanAmount(IAdapter _adapter, uint256 _amount)
        internal
        view
        returns (uint256 flashLoanAmount)
    {
        uint256 debt = vault.getDebt(_adapter.id());
        uint256 collateral = getCollateralInWeth(_adapter);

        uint256 target = targetLtv[_adapter].mulWadDown(_amount + collateral);

        // calculate the flashloan amount needed
        flashLoanAmount = (target - debt).divWadDown(C.ONE - targetLtv[_adapter]);
    }

    //////////////////////////////// DISINVEST /////////////////////////////////////////////

    function _updateAdaptersToDisinvest() internal {
        // for disinvesting check through all the supported adapters everytime
        IAdapter[3] memory allAdapters = [morphoAdapter, compoundV3Adapter, aaveV3Adapter];

        for (uint256 i; i < allAdapters.length; i++) {
            uint256 ltv = getLtv(allAdapters[i]);
            if (ltv > targetLtv[allAdapters[i]] + disinvestThreshold) {
                adaptersToDisinvest.push(allAdapters[i]);
            }
        }
    }

    /// @notice reduces the LTV in protocols where the strategy has overshoot the target ltv due to a loss
    function _disinvest() internal {
        _updateAdaptersToDisinvest();

        if (adaptersToDisinvest.length > 0) {
            (bytes[] memory callData, uint256 totalFlashLoanAmount) = _getDisInvestParams();
            console2.log("\n---- Running Disinvest ----\n");
            vault.rebalance(0, totalFlashLoanAmount, callData);
        }
    }

    function _getDisInvestParams() internal returns (bytes[] memory, uint256) {
        uint256 n = adaptersToDisinvest.length;

        uint256[] memory flashLoanAmounts = new uint[](n);
        uint256 totalFlashLoanAmount;

        for (uint256 i; i < n; i++) {
            flashLoanAmounts[i] = _calcRepayWithdrawFlashLoanAmount(adaptersToDisinvest[i], 0);

            totalFlashLoanAmount += flashLoanAmounts[i];
        }

        bytes[] memory callData = new bytes[](n+1);

        uint256 totalWstEthWithdrawn;
        for (uint256 i; i < n; i++) {
            uint256 withdrawAmount = priceConverter.ethToWstEth(flashLoanAmounts[i]);
            callData[i] = abi.encodeWithSelector(
                scWETHv2.repayAndWithdraw.selector, adaptersToDisinvest[i].id(), flashLoanAmounts[i], withdrawAmount
            );

            totalWstEthWithdrawn += withdrawAmount;
        }

        // swap a little extra wstEth to take account of the amount lost in slippage during wstEth to weth swap
        // since even 1 wei less in weth while paying back the flashloan will cause a revert
        uint256 wstEthToWethSlippageTolerance = 0.001e18;
        uint256 swapAmount = totalWstEthWithdrawn.mulWadDown(C.ONE + wstEthToWethSlippageTolerance);

        bytes memory swapData = getSwapData(swapAmount, C.WSTETH, C.WETH);

        if (swapData.length > 0) {
            callData[n] = abi.encodeWithSelector(
                BaseV2Vault.zeroExSwap.selector,
                C.WSTETH,
                C.WETH,
                swapAmount,
                swapData,
                C.ONE - wstEthToWethSlippageTolerance
            );
        } else {
            callData[n] = abi.encodeWithSelector(
                scWETHv2.swapWstEthToWeth.selector, type(uint256).max, C.ONE - wstEthToWethSlippageTolerance
            );
        }

        return (callData, totalFlashLoanAmount);
    }

    function _calcRepayWithdrawFlashLoanAmount(IAdapter adapter, uint256 amount)
        internal
        view
        returns (uint256 flashLoanAmount)
    {
        uint256 debt = vault.getDebt(adapter.id());
        uint256 collateral = getCollateralInWeth(adapter);

        uint256 target = targetLtv[adapter].mulWadDown(amount + collateral);

        // calculate the flashloan amount needed
        flashLoanAmount = (debt - target).divWadDown(C.ONE - targetLtv[adapter]);
    }

    //////////////////////////////// HELPERS /////////////////////////////////////////////

    function getSwapData(uint256 _amount, address _from, address _to) public virtual returns (bytes memory swapData) {
        string memory url = string(
            abi.encodePacked(
                "https://api.0x.org/swap/v1/quote?buyToken=",
                _to.toHexString(),
                "&sellToken=",
                _from.toHexString(),
                "&sellAmount=",
                _amount.toString()
            )
        );

        string[] memory headers = new string[](1);
        headers[0] = string(abi.encodePacked("0x-api-key: ", vm.envString("ZEROX_API_KEY")));
        (uint256 status, bytes memory data) = url.get(headers);

        if (status != 200) {
            console2.log("----- 0x GET request Failed ---- Using backup swappers -------");
        } else {
            string memory json = string(data);
            swapData = json.readBytes(".data");
        }
    }

    function _logs() internal view {
        uint256 collateralInWeth = priceConverter.wstEthToEth(vault.totalCollateral());
        uint256 debt = vault.totalDebt();
        console2.log("\n Total Collateral %s weth", collateralInWeth);
        console2.log("\n Total Debt %s weth", debt);
        console2.log("\n Invested Amount %s weth", collateralInWeth - debt);
        console2.log("\n Total Assets %s weth", vault.totalAssets());
        console2.log("\n Net Leverage", getLeverage());
        console2.log("\n Net LTV", debt.divWadUp(collateralInWeth));
        console2.log("\n WstEth Balance", ERC20(C.WSTETH).balanceOf(address(this)));
    }
}
