// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

import "forge-std/console.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {IPool} from "aave-v3/interfaces/IPool.sol";
import {IAToken} from "aave-v3/interfaces/IAToken.sol";
import {IVariableDebtToken} from "aave-v3/interfaces/IVariableDebtToken.sol";
import {IEulerDToken, IEulerEToken, IEulerMarkets} from "lib/euler-interfaces/contracts/IEuler.sol";
import {TokenSwapFailed, AmountReceivedBelowMin} from "../errors/scErrors.sol";

import {Constants as C} from "../lib/Constants.sol";
import {sc4626} from "../sc4626.sol";
import {ICurvePool} from "../interfaces/curve/ICurvePool.sol";
import {ILido} from "../interfaces/lido/ILido.sol";
import {IwstETH} from "../interfaces/lido/IwstETH.sol";
import {AggregatorV3Interface} from "../interfaces/chainlink/AggregatorV3Interface.sol";
import {IVault} from "../interfaces/balancer/IVault.sol";
import {IFlashLoanRecipient} from "../interfaces/balancer/IFlashLoanRecipient.sol";
import {IComet} from "../interfaces/compound-v3/IComet.sol";
import {scWETHv2} from "./scWETHv2.sol";

contract LendingMarketManager {
    using SafeTransferLib for ERC20;
    using FixedPointMathLib for uint256;

    enum Protocol {
        AAVE_V3,
        COMPOUND_V3,
        EULER
    }

    struct AaveV3 {
        address pool;
        address aWstEth;
        address varDWeth;
    }

    struct Euler {
        address protocol;
        address markets;
        address eWstEth;
        address dWeth;
    }

    struct Compound {
        address comet;
    }

    // Lido staking contract (stETH)
    ILido public immutable stEth;
    IwstETH public immutable wstETH;
    WETH public immutable weth;

    IPool public immutable aaveV3pool;
    IAToken public immutable aaveV3aWstEth;
    ERC20 public immutable aaveV3varDWeth;

    address public immutable eulerProtocol;
    IEulerMarkets public immutable eulerMarkets;
    IEulerEToken public immutable eulerEWstEth;
    IEulerDToken public immutable eulerDWeth;

    IComet public immutable compoundV3Comet;

    constructor(
        address _stEth,
        address _wstEth,
        address _weth,
        AaveV3 memory aaveV3,
        Euler memory euler,
        Compound memory compound
    ) {
        stEth = ILido(_stEth);
        wstETH = IwstETH(_wstEth);
        weth = WETH(payable(_weth));

        aaveV3pool = IPool(aaveV3.pool);
        aaveV3aWstEth = IAToken(aaveV3.aWstEth);
        aaveV3varDWeth = ERC20(aaveV3.varDWeth);

        eulerProtocol = euler.protocol;
        eulerMarkets = IEulerMarkets(euler.markets);
        eulerEWstEth = IEulerEToken(euler.eWstEth);
        eulerDWeth = IEulerDToken(euler.dWeth);

        compoundV3Comet = IComet(compound.comet);
    }

    function setApprovals() external {
        address aaveV3Pool = address(aaveV3pool);
        address compoundComet = address(compoundV3Comet);

        ERC20(address(stEth)).safeApprove(address(wstETH), type(uint256).max);
        ERC20(address(wstETH)).safeApprove(aaveV3Pool, type(uint256).max);
        ERC20(address(weth)).safeApprove(aaveV3Pool, type(uint256).max);
        ERC20(address(wstETH)).safeApprove(compoundComet, type(uint256).max);
        ERC20(address(weth)).safeApprove(compoundComet, type(uint256).max);

        // set e-mode on aave-v3 for increased borrowing capacity to 90% of collateral
        IPool(aaveV3Pool).setUserEMode(C.AAVE_EMODE_ID);
    }

    function approveEuler() external {
        ERC20(address(wstETH)).safeApprove(address(eulerProtocol), type(uint256).max);
        ERC20(weth).safeApprove(address(eulerProtocol), type(uint256).max);

        // Enter the euler collateral market (collateral's address, *not* the eToken address) ,
        IEulerMarkets(address(eulerMarkets)).enterMarket(0, address(wstETH));
    }

    // supply wstEth to the respective protocol
    function supply(Protocol protocolId, uint256 amount) internal {
        if (protocolId == Protocol.AAVE_V3) {
            aaveV3pool.supply(address(wstETH), amount, address(this), 0);
        } else if (protocolId == Protocol.COMPOUND_V3) {
            compoundV3Comet.supply(address(wstETH), amount);
        } else if (protocolId == Protocol.EULER) {
            eulerEWstEth.deposit(0, amount);
        }
    }

    function borrow(Protocol protocolId, uint256 amount) internal {
        if (protocolId == Protocol.AAVE_V3) {
            aaveV3pool.borrow(address(weth), amount, C.AAVE_VAR_INTEREST_RATE_MODE, 0, address(this));
        } else if (protocolId == Protocol.COMPOUND_V3) {
            compoundV3Comet.withdraw(address(weth), amount);
        } else if (protocolId == Protocol.EULER) {
            eulerDWeth.borrow(0, amount);
        }
    }

    function repay(Protocol protocolId, uint256 amount) internal {
        if (protocolId == Protocol.AAVE_V3) {
            aaveV3pool.repay(address(weth), amount, C.AAVE_VAR_INTEREST_RATE_MODE, address(this));
        } else if (protocolId == Protocol.COMPOUND_V3) {
            compoundV3Comet.supply(address(weth), amount);
        } else if (protocolId == Protocol.EULER) {
            eulerDWeth.repay(0, amount);
        }
    }

    function withdraw(Protocol protocolId, uint256 amount) internal {
        if (protocolId == Protocol.AAVE_V3) {
            aaveV3pool.withdraw(address(wstETH), amount, address(this));
        } else if (protocolId == Protocol.COMPOUND_V3) {
            compoundV3Comet.withdraw(address(wstETH), amount);
        } else if (protocolId == Protocol.EULER) {
            eulerEWstEth.withdraw(0, amount);
        }
    }

    function supplyBorrow(scWETHv2.SupplyBorrowParam[] memory params) external {
        uint256 n = params.length;
        if (n != 0) {
            for (uint256 i; i < n; i++) {
                supply(params[i].protocol, params[i].supplyAmount); // supplyAmount must be in wstEth
                borrow(params[i].protocol, params[i].borrowAmount); // borrowAmount must be in weth
            }
        }
    }

    function repayWithdraw(scWETHv2.RepayWithdrawParam[] memory params) external {
        uint256 n = params.length;
        if (n != 0) {
            for (uint256 i; i < n; i++) {
                if (params[i].repayAmount > getDebt(params[i].protocol, address(this))) {
                    repay(params[i].protocol, type(uint256).max);
                    withdraw(params[i].protocol, type(uint256).max);
                } else {
                    repay(params[i].protocol, params[i].repayAmount); // repayAmount must be in weth
                    withdraw(params[i].protocol, params[i].withdrawAmount); // withdrawAmount must be in wstEth
                }
            }
        }
    }

    // number of lending markets we are currently using
    function totalMarkets() external pure returns (uint256) {
        return uint256(type(Protocol).max) + 1;
    }

    function getDebt(Protocol protocolId, address account) public view returns (uint256 debt) {
        if (protocolId == Protocol.AAVE_V3) {
            debt = aaveV3varDWeth.balanceOf(account);
        } else if (protocolId == Protocol.COMPOUND_V3) {
            debt = compoundV3Comet.borrowBalanceOf(account);
        } else if (protocolId == Protocol.EULER) {
            debt = eulerDWeth.balanceOf(account);
        }
    }

    /// @dev in terms of wstEth (not the asset weth)
    function getCollateral(Protocol protocolId, address account) public view returns (uint256 collateral) {
        if (protocolId == Protocol.AAVE_V3) {
            collateral = aaveV3aWstEth.balanceOf(account);
        } else if (protocolId == Protocol.COMPOUND_V3) {
            collateral = compoundV3Comet.userCollateral(account, address(wstETH)).balance;
        } else if (protocolId == Protocol.EULER) {
            collateral = eulerEWstEth.balanceOfUnderlying(account);
        }
    }

    function getMaxLtv(Protocol protocolId) public view returns (uint256 maxLtv) {
        if (protocolId == Protocol.AAVE_V3) {
            maxLtv = uint256(aaveV3pool.getEModeCategoryData(C.AAVE_EMODE_ID).ltv) * 1e14;
        } else if (protocolId == Protocol.COMPOUND_V3) {
            maxLtv = compoundV3Comet.getAssetInfoByAddress(address(wstETH)).borrowCollateralFactor;
        } else if (protocolId == Protocol.EULER) {
            uint256 collateralFactor = eulerMarkets.underlyingToAssetConfig(address(wstETH)).collateralFactor;
            uint256 borrowFactor = eulerMarkets.underlyingToAssetConfig(address(weth)).borrowFactor;

            uint256 scaledCollateralFactor = collateralFactor.divWadDown(C.EULER_CONFIG_FACTOR_SCALE);
            uint256 scaledBorrowFactor = borrowFactor.divWadDown(C.EULER_CONFIG_FACTOR_SCALE);

            maxLtv = scaledCollateralFactor.mulWadDown(scaledBorrowFactor);
        }
    }

    function getTotalCollateral(address account) external view returns (uint256) {
        return getCollateral(Protocol.AAVE_V3, account) + getCollateral(Protocol.COMPOUND_V3, account)
            + getCollateral(Protocol.EULER, account);
    }

    function getTotalDebt(address account) external view returns (uint256) {
        return getDebt(Protocol.AAVE_V3, account) + getDebt(Protocol.COMPOUND_V3, account)
            + getDebt(Protocol.EULER, account);
    }

    function swapTokens(
        bytes calldata swapData,
        address inToken,
        address outToken,
        uint256 amountIn,
        uint256 amountOutMin
    ) external returns (uint256 inTokenAmount, uint256 outTokenAmount) {
        uint256 inBalance = ERC20(inToken).balanceOf(address(this));
        uint256 outBalance = ERC20(outToken).balanceOf(address(this));

        ERC20(inToken).safeApprove(C.ZEROX_ROUTER, amountIn);

        (bool success,) = C.ZEROX_ROUTER.call{value: outToken == address(0) ? amountIn : 0}(swapData);
        if (!success) revert TokenSwapFailed(inToken, outToken);

        inTokenAmount = inBalance - ERC20(inToken).balanceOf(address(this));
        outTokenAmount = ERC20(outToken).balanceOf(address(this)) - outBalance;

        if (ERC20(outToken).balanceOf(address(this)) - outTokenAmount < amountOutMin) revert AmountReceivedBelowMin();
    }
}
