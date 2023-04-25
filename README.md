# Sandclock V2 

🪃 **Sandclock V2** 🪃 is a set of yield strategies on mainnet, implemented as [ERC4626-compliant](https://eips.ethereum.org/EIPS/eip-4626) tokenized vaults. 

[![Coverage Status](https://coveralls.io/repos/github/lindy-labs/sandclock-contracts/badge.svg)](https://coveralls.io/github/lindy-labs/sandclock-contracts)

## Strategies
- **scWETH** - Deposit WETH/ETH and have it enter a leveraged staked ETH position with additional borrow/supply returns. Receive scWETH shares which appreciate over time when the vault is profitable and can be redeemed for WETH. A keeper bot regularly rebalances the position against a target loan to value ratio in order to compound profits or de-risk position. Strategy has exposure to [Lido finance](https://lido.fi/), [Curve stETH-ETH LP](https://classic.curve.fi/steth/risks), [Balancer](https://balancer.fi/), [Aave V3](https://docs.aave.com/risk/) and the [Chainlink stETH/ETH](https://data.chain.link/ethereum/mainnet/crypto-eth/steth-eth) price feed.
- **scUSDC** - Deposit USDC and over-collateralize it against WETH which will be deposited into scWETH strategy. Receive scUSDC shares which appreciate over time when the vault is profitable and can be redeemed for USDC. A keeper bot regularly rebalances the position against a target loan to value ratio in order to compound profits or de-risk position. Strategy has exposure to scWETH, [Aave V3](https://docs.aave.com/risk/), [Balancer](https://balancer.fi/), [Uniswap V3](https://uniswap.org/) and the [Chainlink USDC/ETH](https://data.chain.link/ethereum/mainnet/stablecoins/usdc-eth) price feed.

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
