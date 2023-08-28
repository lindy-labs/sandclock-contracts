// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";

import {CREATE3Script} from "../../base/CREATE3Script.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Surl} from "surl/Surl.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";
import {stdJson} from "forge-std/StdJson.sol";

import {Constants as C} from "../../../src/lib/Constants.sol";
import {ISwapRouter} from "../../../src/interfaces/uniswap/ISwapRouter.sol";
import {sc4626} from "../../../src/sc4626.sol";
import {scWETHv2} from "../../../src/steth/scWETHv2.sol";
import {BaseV2Vault} from "../../../src/steth/BaseV2Vault.sol";
import {scUSDCv2} from "../../../src/steth/scUSDCv2.sol";
import {Swapper} from "../../../src/steth/Swapper.sol";
import {PriceConverter} from "../../../src/steth/PriceConverter.sol";
import {MorphoAaveV3ScWethAdapter as scWethMorphoAdapter} from
    "../../../src/steth/scWethV2-adapters/MorphoAaveV3ScWethAdapter.sol";
import {CompoundV3ScWethAdapter as scWethCompoundV3Adapter} from
    "../../../src/steth/scWethV2-adapters/CompoundV3ScWethAdapter.sol";
import {IAdapter} from "../../../src/steth/IAdapter.sol";
import {scWETHv2Helper} from "../../../test/helpers/scWETHv2Helper.sol";
import {scWETHv2StrategyParams as Params} from "../../base/scWETHv2StrategyParams.sol";

/**
 * Contract containing the base methods required by all scWETHv2 scripts
 */
contract scWETHv2Utils is CREATE3Script {
    using FixedPointMathLib for uint256;
    using Surl for *;
    using Strings for *;
    using stdJson for string;

    WETH weth = WETH(payable(C.WETH));

    scWETHv2 vault = scWETHv2(payable(0x4c406C068106375724275Cbff028770C544a1333));
    PriceConverter priceConverter = PriceConverter(0xD76B0Ff4A487CaFE4E19ed15B73f12f6A92095Ca);

    IAdapter morphoAdapter = IAdapter(0x4420F0E6A38863330FD4885d76e1265DAD5aa9df);
    IAdapter compoundV3Adapter = IAdapter(0x379022F4d2619c7fbB95f9005ea0897e3a31a0C4);

    mapping(IAdapter => uint256) targetLtv;

    constructor() CREATE3Script(vm.envString("VERSION")) {
        targetLtv[morphoAdapter] = Params.MORPHO_TARGET_LTV;
        targetLtv[compoundV3Adapter] = Params.COMPOUNDV3_TARGET_LTV;
    }

    /// @dev invest the float lying in the vault to morpho and compoundV3
    /// @dev also reinvests profits made,i.e increases the ltv
    /// @dev if there is no undelying float in the contract, run this method with _amount=0 to just reinvest profits
    function _invest() internal {
        uint256 float = weth.balanceOf(address(vault));
        uint256 investAmount = float - vault.minimumFloatAmount();

        console2.log("\nInvesting %s weth", float);

        (bytes[] memory callData,, uint256 totalFlashLoanAmount) = _getInvestParams(investAmount);

        vault.rebalance(investAmount, totalFlashLoanAmount, callData);
    }

    /// @return : supplyBorrowParams, totalSupplyAmount, totalDebtTaken
    /// @dev : NOTE: ASSUMING ZERO BALANCER FLASH LOAN FEES
    function _getInvestParams(uint256 _amount) internal returns (bytes[] memory, uint256, uint256) {
        // require(
        //     Params.MORPHO_ALLOCATION_PERCENT + Params.COMPOUNDV3_ALLOCATION_PERCENT == 1e18,
        //     "allocationPercents dont add up to 100%"
        // );

        uint256 stEthRateTolerance = 0.999e18;

        uint256 morphoAmount = _amount.mulWadDown(Params.MORPHO_ALLOCATION_PERCENT);
        uint256 compoundAmount = _amount.mulWadDown(Params.COMPOUNDV3_ALLOCATION_PERCENT);

        uint256 morphoFlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(morphoAdapter, morphoAmount);
        uint256 compoundFlashLoanAmount = _calcSupplyBorrowFlashLoanAmount(compoundV3Adapter, compoundAmount);

        uint256 morphoSupplyAmount =
            priceConverter.ethToWstEth(morphoAmount + morphoFlashLoanAmount).mulWadDown(stEthRateTolerance);
        uint256 compoundSupplyAmount =
            priceConverter.ethToWstEth(compoundAmount + compoundFlashLoanAmount).mulWadDown(stEthRateTolerance);

        uint256 totalFlashLoanAmount = morphoFlashLoanAmount + compoundFlashLoanAmount;

        bytes[] memory callData = new bytes[](3);

        uint256 wethSwapAmount = _amount + totalFlashLoanAmount;
        bytes memory swapData = swapDataWethToWstEth(wethSwapAmount);

        callData[0] =
            abi.encodeWithSelector(BaseV2Vault.zeroExSwap.selector, C.WETH, C.WSTETH, wethSwapAmount, swapData, 1);

        callData[1] = abi.encodeWithSelector(
            scWETHv2.supplyAndBorrow.selector, morphoAdapter.id(), morphoSupplyAmount, morphoFlashLoanAmount
        );
        callData[2] = abi.encodeWithSelector(
            scWETHv2.supplyAndBorrow.selector, compoundV3Adapter.id(), compoundSupplyAmount, compoundFlashLoanAmount
        );

        return (callData, morphoSupplyAmount + compoundSupplyAmount, totalFlashLoanAmount);
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

    function getCollateralInWeth(IAdapter adapter) public view returns (uint256) {
        return priceConverter.wstEthToEth(adapter.getCollateral(address(vault)));
    }

    /// @notice returns the net leverage that the strategy is using right now (1e18 = 100%)
    function getLeverage() public view returns (uint256) {
        uint256 collateral = priceConverter.wstEthToEth(vault.totalCollateral());
        return collateral > 0 ? collateral.divWadUp(collateral - vault.totalDebt()) : 0;
    }

    function swapDataWethToWstEth(uint256 _amount) internal returns (bytes memory swapData) {
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
}
