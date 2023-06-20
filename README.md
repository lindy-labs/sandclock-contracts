# Sandclock V2 

🪃 **Sandclock V2** 🪃 is a set of yield strategies and staking contracts on mainnet, implemented as [ERC4626-compliant](https://eips.ethereum.org/EIPS/eip-4626) tokenized vaults. 

[![Coverage Status](https://coveralls.io/repos/github/lindy-labs/sandclock-contracts/badge.svg)](https://coveralls.io/github/lindy-labs/sandclock-contracts)

## Vaults
- 🦎 **scWETH** - Deposit WETH/ETH and have it enter a leveraged staked ETH position with additional borrow/supply returns. Receive scWETH shares which appreciate over time when the vault is profitable and can be redeemed for WETH. A keeper bot regularly rebalances the position against a target loan to value ratio in order to compound profits or de-risk position. Strategy has exposure to [Lido finance](https://lido.fi/), [Curve stETH-ETH LP](https://classic.curve.fi/steth/risks), [Balancer](https://balancer.fi/), [Aave V3](https://docs.aave.com/risk/) and the [Chainlink stETH/ETH](https://data.chain.link/ethereum/mainnet/crypto-eth/steth-eth) price feed.
- 🍄 **scUSDC** - Deposit USDC and over-collateralize it against WETH which will be deposited into scWETH strategy. Receive scUSDC shares which appreciate over time when the vault is profitable and can be redeemed for USDC. A keeper bot regularly rebalances the position against a target loan to value ratio in order to compound profits or de-risk position. Strategy has exposure to scWETH, [Aave V3](https://docs.aave.com/risk/), [Balancer](https://balancer.fi/), [Uniswap V3](https://uniswap.org/) and the [Chainlink USDC/ETH](https://data.chain.link/ethereum/mainnet/stablecoins/usdc-eth) price feed.
- 🛼 **scUSDCv2 & scWETHv2** are lender-neutral versions of **scUSDC/scWETH**. They introduce adapters in order to borrow and supply from multiple lending protocols. Adapters can be added at will by a multi-sig and a keeper bot regularly rebalances the positions against a target loan to value ratio and allocation configuration in order to compound profits and/or de-risk positions.
- 🐤 **scLUSD:** Deposit LUSD which will be deposited into the Liquity Stability Pool. Receive scLUSD shares which appreciate over time and can be redeemed for LUSD. A keeper bot regularly reinvests profits which consists of discounted ETH on liquidations and Liquity community issuance ($LQTY). Strategy has exposure to [Liquity](https://www.liquity.org), [0x exchange](https://0x.org/docs) routing protocol and a [combination oracle](https://etherscan.io/address/0x60c0b047133f696334a2b7f68af0b49d2F3D4F72) consisting of [Chainlink ETH/USD](https://data.chain.link/ethereum/mainnet/crypto-usd/eth-usd) and the [Chainlink LUSD/USD](https://etherscan.io/address/0x60c0b047133f696334a2b7f68af0b49d2F3D4F72) price feeds.
- 💎 **sQuartz:** Deposit Quartz for sQuartz and over time claim performance fees from Sandclock yield strategies. Additionally receive bonus multiplier points (inspired by [GMX reward mechanism](https://gmxio.gitbook.io/gmx/rewards)) at 100% APR which can be compounded in order to claim a bigger portion of the staking rewards. Redeem sQuartz for Quartz, which will proportionally burn some of the earned multiplier points for that account. The first 30 days of a deposit special rules apply: no additional deposits allowed and in order to withdraw/transfer a fee needs to be paid (starts at 10% of the amount and linearly decreases to zero over 30 days).

## Installation

To install with [Foundry](https://github.com/gakonst/foundry):

```
forge install lindy-labs/sandclock-contracts
```

## Local development

This project uses [Foundry](https://github.com/gakonst/foundry) as the development framework.

### Dependencies

```
forge install
```

### Compilation

```
forge build
```

### Testing

```
forge test
```

### Contract deployment

Please create a `.env` file before deployment. An example can be found in `.env.example`.

#### Dryrun

```
forge script script/[Script].s.sol --rpc-url [RPC URL]
```

### Live

```
forge script script/[Script].s.sol --rpc-url [RPC URL] --broadcast --verify
```
