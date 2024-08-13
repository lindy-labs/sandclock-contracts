// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.19;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IPoolDataProvider} from "aave-v3/interfaces/IPoolDataProvider.sol";

import {scSkeleton} from "./scSkeleton.sol";
import {Constants as C} from "../lib/Constants.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IAdapter} from "./IAdapter.sol";
import {Swapper} from "./Swapper.sol";
import {PriceConverter} from "./PriceConverter.sol";
import {MainnetAddresses as MA} from "../../script/base/MainnetAddresses.sol";

// TODO: reorder constructor params
contract scUSDT is scSkeleton {
    using Address for address;

    constructor(address _admin, address _keeper, PriceConverter _priceConverter, Swapper _swapper)
        scSkeleton(
            "Sandclock USDT Vault",
            "scUSDT",
            ERC20(C.USDT),
            ERC4626(MA.SCWETHV2),
            _admin,
            _keeper,
            _priceConverter,
            _swapper
        )
    {}

    function _swapTargetTokenForAsset(uint256 _wethAmount, uint256 _usdtAmountOutMin)
        internal
        virtual
        override
        returns (uint256 usdtReceived)
    {
        bytes memory result = address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                Swapper.uniswapSwapExactInput.selector, C.WETH, C.USDT, _wethAmount, _usdtAmountOutMin, 500
            )
        );

        usdtReceived = abi.decode(result, (uint256));
    }

    function _swapAssetForExactTargetToken(uint256 _targetTokenAmountOut) internal virtual override {
        address(swapper).functionDelegateCall(
            abi.encodeWithSelector(
                Swapper.uniswapSwapExactOutput.selector, C.USDT, C.WETH, _targetTokenAmountOut, type(uint256).max, 500
            )
        );
    }
}

contract scUSDTPriceConverter is PriceConverter {
    using FixedPointMathLib for uint256;

    AggregatorV3Interface public usdtToEthPriceFeed = AggregatorV3Interface(0xEe9F2375b4bdF6387aa8265dD4FB8F16512A1d46);

    // the admin address provided here does not matter
    // if any change is required we should update the
    // whole price converter contract address directly
    constructor() PriceConverter(MA.MULTISIG) {}

    /**
     * @notice eth To usdt
     */
    function targetTokenToAsset(uint256 _amount) public view override returns (uint256) {
        return _amount.divWadDown(_usdtPriceInEth() * C.WETH_USDC_DECIMALS_DIFF);
    }

    /**
     * @notice usdt to eth
     */
    function assetToTargetToken(uint256 _amount) public view override returns (uint256) {
        return (_amount * C.WETH_USDC_DECIMALS_DIFF).mulWadDown(_usdtPriceInEth());
    }

    function _usdtPriceInEth() internal view returns (uint256) {
        (, int256 usdtPriceInEth,,,) = usdtToEthPriceFeed.latestRoundData();

        return uint256(usdtPriceInEth);
    }
}

/**
 * @title Aave v3 Lending Protocol Adapter
 * @notice Facilitates lending and borrowing for the Aave v3 lending protocol
 */
contract AaveV3ScUsdtAdapter is IAdapter {
    using SafeTransferLib for ERC20;
    using SafeTransferLib for WETH;

    ERC20 constant usdt = ERC20(C.USDT);
    WETH constant weth = WETH(payable(C.WETH));

    // Aave v3 pool contract
    IPool public constant pool = IPool(C.AAVE_V3_POOL);
    // Aave v3 pool data provider contract
    IPoolDataProvider public constant aaveV3PoolDataProvider = IPoolDataProvider(C.AAVE_V3_POOL_DATA_PROVIDER);
    // Aave v3 "aEthUSDT" token (supply token)
    ERC20 public constant aUsdt = ERC20(0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a);
    // Aave v3 "variableDebtEthWETH" token (variable debt token)
    ERC20 public constant dWeth = ERC20(C.AAVE_V3_VAR_DEBT_WETH_TOKEN);

    /// @inheritdoc IAdapter
    uint256 public constant override id = 1;

    /// @inheritdoc IAdapter
    function setApprovals() external override {
        usdt.safeApprove(address(pool), type(uint256).max);
        weth.safeApprove(address(pool), type(uint256).max);
    }

    /// @inheritdoc IAdapter
    function revokeApprovals() external override {
        usdt.safeApprove(address(pool), 0);
        weth.safeApprove(address(pool), 0);
    }

    /// @inheritdoc IAdapter
    function supply(uint256 _amount) external override {
        pool.supply(address(usdt), _amount, address(this), 0);
    }

    /// @inheritdoc IAdapter
    function borrow(uint256 _amount) external override {
        pool.borrow(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
    }

    /// @inheritdoc IAdapter
    function repay(uint256 _amount) external override {
        pool.repay(address(weth), _amount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
    }

    /// @inheritdoc IAdapter
    function withdraw(uint256 _amount) external override {
        pool.withdraw(address(usdt), _amount, address(this));
    }

    /// @inheritdoc IAdapter
    function claimRewards(bytes calldata) external pure override {
        revert("not applicable");
    }

    /// @inheritdoc IAdapter
    function getCollateral(address _account) external view override returns (uint256) {
        return aUsdt.balanceOf(_account);
    }

    /// @inheritdoc IAdapter
    function getDebt(address _account) external view override returns (uint256) {
        return dWeth.balanceOf(_account);
    }

    /// @inheritdoc IAdapter
    function getMaxLtv() external view override returns (uint256) {
        (, uint256 ltv,,,,,,,,) = aaveV3PoolDataProvider.getReserveConfigurationData(address(usdt));

        // ltv is returned as a percentage with 2 decimals (e.g. 80% = 8000) so we need to multiply by 1e14
        return ltv * 1e14;
    }
}
