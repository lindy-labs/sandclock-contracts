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
 * invest float if there is any
 * reinvest profits/ increase back the ltv of the protocol to the target ltv
 * disinvest/ decrease the ltv of any protocol if it has overshoot by a threshold (disinvestThreshold)
 * also if the vault has float less than minimumFloat amount, withdraw the required float to the vault
 *
 * cmd
 * first run a local anvil node using " anvil -f YOUR_RPC_URL"
 * Then run the script using
 * forge script script/v2/manual-runs/scWETHv2Rebalance.s.sol --rpc-url http://127.0.0.1:8545 --ffi
 */
contract RebalanceScWethV2 is Script, scWETHv2Helper {
    using FixedPointMathLib for uint256;
    using Surl for *;
    using Strings for *;
    using stdJson for string;

    ////////////////////////// BUTTONS ///////////////////////////////
    uint256 public morphoInvestableAmountPercent = 0.4e18;
    uint256 public morphoTargetLtv = 0.8e18;

    uint256 public compoundV3InvestableAmountPercent = 0.6e18;
    uint256 public compoundV3TargetLtv = 0.8e18;

    uint256 public aaveV3InvestableAmountPercent = 0;
    uint256 public aaveV3TargetLtv = 0.8e18;

    // if the ltv overshoots the target ltv by this threshold, disinvest
    uint256 public disinvestThreshold = 0.005e18; // 0.5 %

    // be it weth gained from profits or float amount lying in the vault
    // the contract rebalance method won't be called if the minimum amount to invest is less than this threshold
    uint256 public minimumInvestAmount = 0.1 ether;

    // this percent of wstEth will only be supplied for each adapter (instead of the whole calculated supply amount)
    // since while swapping from weth to wstEth we get a little less wstEth than expected due to slippage
    // so if the contract tries to supply the exact supplyAmount of wstEth calculated, it will revert on the last supply since the contract
    // wont have enough wstEth funds for the supply
    uint256 stEthRateTolerance = 0.9995e18;

    ///////////////////////////////////////////////////////////////////////

    struct RebalanceDataParams {
        IAdapter adapter;
        uint256 flashLoanAmount;
        uint256 supplyAmount;
        uint256 withdrawAmount;
    }

    error ScriptAdapterNotSupported(uint256 adapterId);
    error FloatRequiredIsMoreThanTotalInvested();

    uint256 keeperPrivateKey = uint256(vm.envOr("KEEPER_PRIVATE_KEY", bytes32(0x00)));
    address keeper = keeperPrivateKey != 0 ? vm.addr(keeperPrivateKey) : MA.KEEPER;

    WETH weth = WETH(payable(C.WETH));

    IAdapter public morphoAdapter = IAdapter(MA.SCWETHV2_MORPHO_ADAPTER);
    IAdapter public compoundV3Adapter = IAdapter(MA.SCWETHV2_COMPOUND_ADAPTER);
    IAdapter public aaveV3Adapter = IAdapter(MA.SCWETHV2_AAVEV3_ADAPTER);

    mapping(IAdapter => uint256) public targetLtv;

    RebalanceDataParams[] rebalanceDataParams;
    bytes[] private multicallData;
    mapping(IAdapter => uint256) public adapterAllocationPercent;

    uint256 investFlashLoanAmount;
    uint256 disinvestFlashLoanAmount;
    uint256 totalWstEthWithdrawn;
    uint256 totalFlashLoanAmount;

    constructor() scWETHv2Helper(scWETHv2(payable(MA.SCWETHV2)), PriceConverter(MA.PRICE_CONVERTER)) {}

    function run() external {
        _logs("-------------------BEFORE REBALANCE-------------------");

        _initializeAdapterSettings();

        // if the vault has float less than minimumFloat amount, withdraw it to the vault
        _updateVaultFloat();

        uint256 investAmount = _calcInvestAmount();
        _createRebalanceParams(investAmount);
        _createRebalanceMulticallData(investAmount);

        if (totalFlashLoanAmount > minimumInvestAmount.mulWadDown(getLeverage())) {
            vm.startBroadcast(keeper);

            vault.rebalance(investAmount, totalFlashLoanAmount, multicallData);

            vm.stopBroadcast();
        }

        _logs("-------------------AFTER REBALANCE-------------------");
    }

    function _initializeAdapterSettings() internal {
        uint256 totalAllocationPercent;

        adapterAllocationPercent[morphoAdapter] = morphoInvestableAmountPercent;
        targetLtv[morphoAdapter] = morphoTargetLtv;
        totalAllocationPercent += morphoInvestableAmountPercent;

        adapterAllocationPercent[aaveV3Adapter] = aaveV3InvestableAmountPercent;
        targetLtv[aaveV3Adapter] = aaveV3TargetLtv;
        totalAllocationPercent += aaveV3InvestableAmountPercent;

        adapterAllocationPercent[compoundV3Adapter] = compoundV3InvestableAmountPercent;
        targetLtv[compoundV3Adapter] = compoundV3TargetLtv;
        totalAllocationPercent += compoundV3InvestableAmountPercent;

        require(totalAllocationPercent == 1e18, "totalAllocationPercent != 100%");
    }

    function _calcInvestAmount() internal view returns (uint256 investAmount) {
        uint256 float = weth.balanceOf(address(vault));
        uint256 minimumFloat = vault.minimumFloatAmount();

        // investAmount == 0 just reinvests profits
        investAmount = float > minimumFloat ? float - minimumFloat : 0;
    }

    function _createRebalanceParams(uint256 _investAmount) internal {
        IAdapter[3] memory allAdapters = [morphoAdapter, compoundV3Adapter, aaveV3Adapter];

        IAdapter adapter;
        uint256 allocationPercent;

        for (uint256 i; i < allAdapters.length; i++) {
            adapter = allAdapters[i];
            allocationPercent = adapterAllocationPercent[adapter];

            if (!vault.isSupported(adapter.id()) && (targetLtv[adapter] > 0 || allocationPercent > 0)) {
                revert ScriptAdapterNotSupported(adapter.id());
            }
            // first check if allocation Percent is greater than zero
            if (allocationPercent != 0) {
                _createRebalanceDataFor(adapter, _investAmount.mulWadDown(allocationPercent));
            } else {
                // even if there is no allocation here, we still want to check if a disinvest is needed in this protocol
                uint256 ltv = getLtv(adapter);

                if (ltv > targetLtv[adapter] + disinvestThreshold) {
                    _createRebalanceDataFor(adapter, 0);
                }
            }
        }
    }

    function _createRebalanceMulticallData(uint256 _investAmount) internal {
        // 3 scenarios here
        // only invest (calldata length = number of protocols + 1)
        // invest and disinvest (calldata length = number of protocols + 2)
        // only disinvest (calldata length = number of protocols + 1)

        if (investFlashLoanAmount > 0) {
            uint256 wethSwapAmount = investFlashLoanAmount + _investAmount;
            bytes memory swapData = getSwapData(wethSwapAmount, C.WETH, C.WSTETH);

            if (swapData.length > 0) {
                multicallData.push(
                    abi.encodeWithSelector(
                        BaseV2Vault.zeroExSwap.selector, C.WETH, C.WSTETH, wethSwapAmount, swapData, 0
                    )
                );
            } else {
                multicallData.push(abi.encodeWithSelector(scWETHv2.swapWethToWstEth.selector, wethSwapAmount));
            }
        }

        for (uint256 i; i < rebalanceDataParams.length; i++) {
            RebalanceDataParams memory data = rebalanceDataParams[i];

            if (data.supplyAmount > 0) {
                multicallData.push(
                    abi.encodeWithSelector(
                        scWETHv2.supplyAndBorrow.selector, data.adapter.id(), data.supplyAmount, data.flashLoanAmount
                    )
                );

                // console log
                console2.log(
                    "supplying and borrowing from adapter\t",
                    data.adapter.id().toString(),
                    "\tamount\t",
                    data.supplyAmount.toString()
                );
            } else {
                multicallData.push(
                    abi.encodeWithSelector(
                        scWETHv2.repayAndWithdraw.selector, data.adapter.id(), data.flashLoanAmount, data.withdrawAmount
                    )
                );

                // console log
                console2.log(
                    "repaying and withdrawing from adapter\t",
                    data.adapter.id().toString(),
                    "\tamount\t",
                    data.flashLoanAmount.toString()
                );
            }
        }

        if (disinvestFlashLoanAmount > 0) {
            uint256 wstEthToWethSlippageTolerance = 0.001e18;
            uint256 swapAmount = totalWstEthWithdrawn.mulWadDown(C.ONE + wstEthToWethSlippageTolerance);

            bytes memory swapData = getSwapData(swapAmount, C.WSTETH, C.WETH);

            if (swapData.length > 0) {
                multicallData.push(
                    abi.encodeWithSelector(
                        BaseV2Vault.zeroExSwap.selector,
                        C.WSTETH,
                        C.WETH,
                        swapAmount,
                        swapData,
                        C.ONE - wstEthToWethSlippageTolerance
                    )
                );
            } else {
                multicallData.push(
                    abi.encodeWithSelector(
                        scWETHv2.swapWstEthToWeth.selector, type(uint256).max, C.ONE - wstEthToWethSlippageTolerance
                    )
                );
            }
        }

        totalFlashLoanAmount = investFlashLoanAmount + disinvestFlashLoanAmount;
    }

    /// @dev doesn't matter if the vault has to supply/borrow or repay/withdraw
    /// @dev this supports both scenarios
    function _createRebalanceDataFor(IAdapter _adapter, uint256 _amount) internal {
        uint256 flashLoanAmount;
        uint256 debt = vault.getDebt(_adapter.id());
        uint256 collateral = getCollateralInWeth(_adapter);
        uint256 target = targetLtv[_adapter].mulWadDown(_amount + collateral);

        if (target > debt) {
            flashLoanAmount = (target - debt).divWadDown(C.ONE - targetLtv[_adapter]);

            if (flashLoanAmount > 0) {
                uint256 supplyAmount =
                    priceConverter.ethToWstEth(_amount + flashLoanAmount).mulWadDown(stEthRateTolerance);

                rebalanceDataParams.push(RebalanceDataParams(_adapter, flashLoanAmount, supplyAmount, 0));

                investFlashLoanAmount += flashLoanAmount;
            }
        } else {
            flashLoanAmount = (debt - target).divWadDown(C.ONE - targetLtv[_adapter]);

            if (flashLoanAmount > 0) {
                uint256 withdrawAmount = priceConverter.ethToWstEth(flashLoanAmount);

                rebalanceDataParams.push(RebalanceDataParams(_adapter, flashLoanAmount, 0, withdrawAmount));

                totalWstEthWithdrawn += withdrawAmount;
                disinvestFlashLoanAmount += flashLoanAmount;
            }
        }
    }

    function _updateVaultFloat() internal {
        uint256 float = weth.balanceOf(address(vault));
        uint256 minimumFloatAmount = vault.minimumFloatAmount();
        if (float < minimumFloatAmount) {
            uint256 floatRequired = (minimumFloatAmount - float).mulWadDown(C.ONE + 0.05e18); // plus extra 5% to account for slippage errors
            if (vault.totalInvested() > floatRequired) {
                vm.startBroadcast(keeper);
                vault.withdrawToVault(floatRequired);
                vm.stopBroadcast();
            } else {
                revert FloatRequiredIsMoreThanTotalInvested();
            }
        }
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

    function _logs(string memory _msg) internal view {
        console2.log(_msg);

        uint256 collateralInWeth = priceConverter.wstEthToEth(vault.totalCollateral());
        uint256 debt = vault.totalDebt();

        console2.log("total collateral (in WETH)\t", collateralInWeth);
        console2.log("total debt\t\t\t", debt);
        console2.log("invested amount\t\t", collateralInWeth - debt);
        console2.log("total assets\t\t\t", vault.totalAssets());
        console2.log("net leverage\t\t\t", getLeverage());

        if (collateralInWeth != 0) console2.log("net LTV\t\t\t", debt.divWadUp(collateralInWeth));
        console2.log("wstEth balance\t\t", ERC20(C.WSTETH).balanceOf(address(this)));
    }
}
