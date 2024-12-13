// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.13;

library Constants {
    uint256 public constant ONE = 1e18;
    // decimals difference between WETH and USDC (18 - 6)
    uint256 public constant WETH_USDC_DECIMALS_DIFF = 1e12;
    uint256 public constant WETH_USDT_DECIMALS_DIFF = 1e12;
    // value for the variable interest rate mode on Aave
    uint256 public constant AAVE_VAR_INTEREST_RATE_MODE = 2;
    // enable efficeincy mode on Aave (used to allow greater LTV when asset and debt tokens are correlated in price)
    uint8 public constant AAVE_EMODE_ID = 1;
    // vaule used to scale the token's collateral/borrow factors from the euler market
    uint32 constant EULER_CONFIG_FACTOR_SCALE = 4_000_000_000;

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
    // address of the LUSD token contract
    address public constant LUSD = 0x5f98805A4E8be255a32880FDeC7F6728C6568bA0;
    // address of the DAI token contract
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    // address of the sDAI token contract
    address public constant SDAI = 0x83F20F44975D03b1b09e64809B757c47f942BEeA;
    // address of the USDS token contract
    address public constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    // address of the sUSDS token contract
    address public constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    // address of the USDT token contract
    address public constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;

    // address of the Curve pool for ETH-stETH
    address public constant CURVE_ETH_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    // address of the Uniswap v3 swap router contract
    address public constant UNISWAP_V3_SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    // address of the Aave v3 pool contract
    address public constant AAVE_V3_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    // address of the Aave pool data provider contract
    address public constant AAVE_V3_POOL_DATA_PROVIDER = 0x7B4EB56E7CD4b454BA8ff71E4518426369a138a3;
    // address of the Aave Rewards Controller contract
    address public constant AAVE_V3_REWARDS_CONTROLLER = 0x8164Cc65827dcFe994AB23944CBC90e0aa80bFcb;

    // address of the Aave v3 "aEthUSDC" token (supply token)
    address public constant AAVE_V3_AUSDC_TOKEN = 0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c;
    // address of the Aave v3 "aEthUSDS" token (supply token)
    address public constant AAVE_V3_AUSDS_TOKEN = 0x32a6268f9Ba3642Dda7892aDd74f1D34469A4259;
    // address of the Aave v3 "aEthUSDT" token (supply token)
    address public constant AAVE_V3_AUSDT_TOKEN = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;
    // address of the Aave v3 "aEthwstETH" token (supply token)
    address public constant AAVE_V3_AWSTETH_TOKEN = 0x0B925eD163218f6662a35e0f0371Ac234f9E9371;
    // address of the Aave v3 "variableDebtEthWETH" token (variable debt token)
    address public constant AAVE_V3_VAR_DEBT_WETH_TOKEN = 0xeA51d7853EEFb32b6ee06b1C12E6dcCA88Be0fFE;
    // address of the Aave v3 "variableDebtEthWETH" token implementation contract (variable debt token)
    address public constant AAVE_V3_VAR_DEBT_IMPLEMENTATION_CONTRACT = 0xaC725CB59D16C81061BDeA61041a8A5e73DA9EC6;

    address public constant SPARK_POOL = 0xC13e21B648A5Ee794902342038FF3aDAB66BE987;
    address public constant SPARK_POOL_DATA_PROVIDER = 0xFc21d6d146E6086B8359705C8b28512a983db0cb;
    address public constant SPARK_ADAI_TOKEN = 0x4DEDf26112B3Ec8eC46e7E31EA5e123490B05B8B;
    address public constant SPARK_ASDAI_TOKEN = 0x78f897F0fE2d3B5690EbAe7f19862DEacedF10a7;
    address public constant SPARK_VAR_DEBT_WETH_TOKEN = 0x2e7576042566f8D6990e07A1B61Ad1efd86Ae70d;

    // EULER Contracts
    address public constant EULER = 0x27182842E098f60e3D576794A5bFFb0777E025d3;
    address public constant EULER_MARKETS = 0x3520d5a913427E6F0D6A83E07ccD4A4da316e4d3;
    // Euler supply token for wstETH (ewstETH)
    address public constant EULER_ETOKEN_WSTETH = 0xbd1bd5C956684f7EB79DA40f582cbE1373A1D593;
    // Euler supply token for USDC (eUSDC)
    address public constant EULER_ETOKEN_USDC = 0xEb91861f8A4e1C12333F42DCE8fB0Ecdc28dA716;
    // Euler debt token weth
    address public constant EULER_DTOKEN_WETH = 0x62e28f054efc24b26A794F5C1249B6349454352C;
    // address of the EULER rewards token contract
    address public constant EULER_REWARDS_TOKEN = 0xd9Fcd98c322942075A5C3860693e9f4f03AAE07b;

    // adress of the Chainlink aggregator for the USDC/eth price feed
    address public constant CHAINLINK_USDC_ETH_PRICE_FEED = 0x986b5E1e1755e3C2440e960477f25201B0a8bbD4;
    // Chainlink pricefeed (DAI -> ETH)
    address public constant CHAINLINK_DAI_ETH_PRICE_FEED = 0x773616E4d11A78F511299002da57A0a94577F1f4;
    // Chainlink pricefeed (stETH -> ETH)
    address public constant CHAINLINK_STETH_ETH_PRICE_FEED = 0x86392dC19c0b719886221c78AB11eb8Cf5c52812;
    // Chainlink pricefeed (USDT -> ETH)
    address public constant CHAINLINK_USDT_ETH_PRICE_FEED = 0xEe9F2375b4bdF6387aa8265dD4FB8F16512A1d46;

    // Liquity pricefeed (USD -> ETH) with Chainlink as primary and Tellor as backup.
    address public constant LIQUITY_USD_ETH_PRICE_FEED = 0x4c517D4e2C851CA76d7eC94B805269Df0f2201De;

    // address of the Balancer vault contract
    address public constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
    // Balancer admin account
    address public constant BALANCER_ADMIN = 0x97207B095e4D5C9a6e4cfbfcd2C3358E03B90c4A;
    // address of the Balance Protocol Fees Collector contract
    address public constant BALANCER_FEES_COLLECTOR = 0xce88686553686DA562CE7Cea497CE749DA109f9F;

    // address of the 0x swap router contract
    address public constant ZERO_EX_ROUTER = 0xDef1C0ded9bec7F1a1670819833240f027b25EfF;

    // address of Lifi swap router contract
    address public constant LIFI = 0x1231DEB6f5749EF6cE6943a275A1D3E7486F4EaE;

    // Compound v3
    address public constant COMPOUND_V3_COMET_WETH = 0xA17581A9E3356d9A858b789D68B4d866e593aE94;

    // Aave v2 lending pool
    address public constant AAVE_V2_LENDING_POOL = 0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9;
    // Aave v2 protocol data provider
    address public constant AAVE_V2_PROTOCOL_DATA_PROVIDER = 0x057835Ad21a177dbdd3090bB1CAE03EaCF78Fc6d;
    // Aave v2 interest bearing USDC (aUSDC) token
    address public constant AAVE_V2_AUSDC_TOKEN = 0xBcca60bB61934080951369a648Fb03DF4F96263C;
    // Aave v2 variable debt bearing WETH (variableDebtWETH) token
    address public constant AAVE_V2_VAR_DEBT_WETH_TOKEN = 0xF63B34710400CAd3e044cFfDcAb00a0f32E33eCf;

    // Liquity
    address public constant LIQUITY_STABILITY_POOL = 0x66017D22b0f8556afDd19FC67041899Eb65a21bb;
    address public constant LIQUITY_LQTY_TOKEN = 0x6DEA81C8171D0bA574754EF6F8b412F2Ed88c54D;

    // Morpho
    address public constant MORPHO = 0x33333aea097c193e66081E930c33020272b33333;

    // Sky
    address public constant DAI_USDS_CONVERTER = 0x3225737a9Bbb6473CB4a45b7244ACa2BeFdB276A;
}
