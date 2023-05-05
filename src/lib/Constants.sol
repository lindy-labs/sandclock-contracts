// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

library Constants {
    uint256 public constant ONE = 1e18;
    // decimals difference between WETH and USDC (18 - 6)
    uint256 public constant WETH_USDC_DECIMALS_DIFF = 1e12;
    // value for the variable interest rate mode on Aave
    uint256 public constant AAVE_VAR_INTEREST_RATE_MODE = 2;
    // enable efficeincy mode on Aave (used to allow greater LTV when asset and debt tokens are correlated in price)
    uint8 public constant AAVE_EMODE_ID = 1;

    /*//////////////////////////////////////////////////////////////
                          MAINNET ADDRESSES
    //////////////////////////////////////////////////////////////*/

    // address of the USDC token contract
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // address of the WETH token contract
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // address of the wrapped stETH token contract
    address public constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    // address of the Lido stETH token contract
    address public constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;

    // address of the Curve pool for ETH-stETH
    address public constant CURVE_ETH_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    // address of the Uniswap v3 swap router contract
    address public constant UNISWAP_V3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // address of the Aave pool contract
    address public constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    // address of the Aave pool data provider contract
    address public constant AAVE_POOL_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    // address of the Aave "aEthUSDC" token (supply token)
    address public constant AAVE_AUSDC_TOKEN = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    // address of the Aave "aEthwstETH" token (supply token)
    address public constant AAVE_AWSTETH_TOKEN = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    // address of the Aave "variableDebtEthWETH" token (variable debt token)
    address public constant AAVAAVE_VAR_DEBT_WETH_TOKEN = 0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE;

    // EULER Contracts
    address public constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;
    address public constant EULER_MARKETS = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;
    // Euler supply token for wstETH (ewstETH)
    address public constant EULER_ETOKEN_WSTETH = 0xbd1bd5C956684f7EB79DA40f582cbE1373A1D593;
    // Euler debt token weth
    address public constant EULER_DTOKEN_WETH = 0x62e28f054efc24b26A794F5C1249B6349454352C;

    // adress of the Chainlink aggregator for the USDC/eth price feed
    address public constant CHAINLINK_USDC_ETH_PRICE_FEED = 0x986b5E1e1755e3C2440e960477f25201B0a8bbD4;
    // Chainlink pricefeed (stETH -> ETH)
    address public constant CHAINLINK_STETH_ETH_PRICE_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;

    // address of the Balancer vault contract
    address public constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    // address of the 0x swap router contract
    address public constant ZEROX_ROUTER = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    // Compound v3
    address public constant COMPOUND_V3_COMET_WETH = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;
}
