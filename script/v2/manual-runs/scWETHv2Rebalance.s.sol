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
import {scWETHv2StrategyParams as Params} from "../../base/scWETHv2StrategyParams.sol";
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

    uint256 keeperPrivateKey = uint256(vm.envOr("KEEPER_PRIVATE_KEY", bytes32(0x00)));

    WETH weth = WETH(payable(C.WETH));

    IAdapter public morphoAdapter = IAdapter(MA.SCWETHV2_MORPHO_ADAPTER);
    IAdapter public compoundV3Adapter = IAdapter(MA.SCWETHV2_COMPOUND_ADAPTER);
    IAdapter public aaveV3Adapter = IAdapter(MA.SCWETHV2_AAVEV3_ADAPTER);

    mapping(IAdapter => uint256) public targetLtv;

    // to be used for testing
    bytes demoSwapData;

    ////////////////////////// BUTTONS ///////////////////////////////
    uint256 public constant MORPHO_ALLOCATION_PERCENT = 0.4e18;
    uint256 public constant MORPHO_TARGET_LTV = 0.8e18;

    uint256 public constant COMPOUNDV3_ALLOCATION_PERCENT = 0.6e18;
    uint256 public constant COMPOUNDV3_TARGET_LTV = 0.8e18;

    uint256 public constant AAVEV3_ALLOCATION_PERCENT = 0;
    uint256 public constant AAVEV3_TARGET_LTV = 0.8e18;
    ///////////////////////////////////////////////////////////////////////

    constructor() scWETHv2Helper(scWETHv2(payable(MA.SCWETHV2)), PriceConverter(MA.PRICE_CONVERTER)) {
        targetLtv[morphoAdapter] = MORPHO_TARGET_LTV;
        targetLtv[compoundV3Adapter] = COMPOUNDV3_TARGET_LTV;
        targetLtv[aaveV3Adapter] = AAVEV3_TARGET_LTV;
    }

    function run() external {
        address keeper = keeperPrivateKey != 0 ? vm.addr(keeperPrivateKey) : MA.KEEPER;

        vm.startBroadcast(keeper);

        _invest();
        _logs();

        vm.stopBroadcast();
    }

    /// @dev invest the float lying in the vault to morpho and compoundV3
    /// @dev also reinvests profits made,i.e increases the ltv
    /// @dev if there is no undelying float in the contract, run this method with _amount=0 to just reinvest profits
    function _invest() internal {
        uint256 float = weth.balanceOf(address(vault));
        uint256 investAmount = float - vault.minimumFloatAmount();

        console2.log("\nInvesting %s weth", investAmount);

        IAdapter[] memory adapters = new IAdapter[](2);
        adapters[0] = morphoAdapter;
        adapters[1] = compoundV3Adapter;

        uint256[] memory allocationPercents = new uint[](2);
        allocationPercents[0] = Params.MORPHO_ALLOCATION_PERCENT;
        allocationPercents[1] = Params.COMPOUNDV3_ALLOCATION_PERCENT;

        (bytes[] memory callData, uint256 totalFlashLoanAmount) =
            _getInvestParams(investAmount, adapters, allocationPercents);

        vault.rebalance(investAmount, totalFlashLoanAmount, callData);
    }

    // returns callData, totalFlashLoanAmount
    /// @notice Returns the required calldata for investin float or reinvesting profits given the adapters to invest to and their respective allocationPercent
    /// @param _adapters array containing the adapters to invest to
    /// @param _allocationPercents array containing the allocation percents for the adapters respectively
    /// @dev : NOTE: ASSUMING ZERO BALANCER FLASH LOAN FEES
    function _getInvestParams(uint256 _amount, IAdapter[] memory _adapters, uint256[] memory _allocationPercents)
        internal
        returns (bytes[] memory, uint256)
    {
        uint256 stEthRateTolerance = 0.999e18;
        uint256 n = _adapters.length;
        uint256 totalAllocationPercent;

        require(_allocationPercents.length == n, "array lengths don't match");

        uint256[] memory flashLoanAmounts = new uint[](n);
        uint256[] memory supplyAmounts = new uint[](n);

        uint256 totalFlashLoanAmount;

        for (uint256 i; i < n; i++) {
            uint256 adapterInvestAmount = _amount.mulWadDown(_allocationPercents[i]); // amount to be invested in this adapter
            flashLoanAmounts[i] = _calcSupplyBorrowFlashLoanAmount(_adapters[i], adapterInvestAmount);
            supplyAmounts[i] =
                priceConverter.ethToWstEth(adapterInvestAmount + flashLoanAmounts[i]).mulWadDown(stEthRateTolerance);

            totalFlashLoanAmount += flashLoanAmounts[i];
            totalAllocationPercent += _allocationPercents[i];
        }

        require(totalAllocationPercent == 1e18, "totalAllocationPercent != 100%");

        bytes[] memory callData = new bytes[](n+1);

        uint256 wethSwapAmount = _amount + totalFlashLoanAmount;
        bytes memory swapData = demoSwapData.length != 0 ? demoSwapData : getSwapDataWethToWstEth(wethSwapAmount);

        callData[0] =
            abi.encodeWithSelector(BaseV2Vault.zeroExSwap.selector, C.WETH, C.WSTETH, wethSwapAmount, swapData, 0);

        for (uint256 i = 1; i < n + 1; i++) {
            callData[i] = abi.encodeWithSelector(
                scWETHv2.supplyAndBorrow.selector, _adapters[i - 1].id(), supplyAmounts[i - 1], flashLoanAmounts[i - 1]
            );
        }

        return (callData, totalFlashLoanAmount);
    }

    function getSwapDataWethToWstEth(uint256 _amount) public returns (bytes memory swapData) {
        string memory url = string(
            abi.encodePacked(
                "https://api.0x.org/swap/v1/quote?buyToken=0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0&sellToken=WETH&sellAmount=",
                _amount.toString()
            )
        );

        string[] memory headers = new string[](1);
        headers[0] = string(abi.encodePacked("0x-api-key: ", vm.envString("ZEROX_API_KEY")));
        (uint256 status, bytes memory data) = url.get(headers);

        require(status == 200, "0x GET request Failed");

        string memory json = string(data);

        swapData = json.readBytes(".data");
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

    function _logs() internal view {
        uint256 collateralInWeth = priceConverter.wstEthToEth(vault.totalCollateral());
        uint256 debt = vault.totalDebt();
        console2.log("\n Total Collateral %s weth", collateralInWeth);
        console2.log("\n Total Debt %s weth", debt);
        console2.log("\n Invested Amount %s weth", collateralInWeth - debt);
        console2.log("\n Total Assets %s weth", vault.totalAssets());
        console2.log("\n Net Leverage", getLeverage());
        console2.log("\n Net LTV", debt.divWadUp(collateralInWeth));
    }

    ///////////////////////////////// FOR TESTING ONLY ///////////////////////////
    function setDemoSwapData(bytes memory _data) external {
        demoSwapData = _data;
    }
}
