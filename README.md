# Sandclock V2 

Sandclock yield strategies

[![Coverage Status](https://coveralls.io/repos/github/lindy-labs/sandclock-contracts/badge.svg)](https://coveralls.io/github/lindy-labs/sandclock-contracts)

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

### Echidna

Install [echidna](https://github.com/crytic/echidna/releases) and add environment variables `ECHIDNA_RPC_URL` and `ECHIDNA_RPC_BLOCK=16771449`.

```
echidna . --contract [Harness] --config echidna.yaml
```

### Contract deployment

Please create a `.env` file before deployment. An example can be found in `.env.example`.

#### Dryrun

```
forge script script/Deploy.s.sol -f [network]
```

### Live

```
forge script script/Deploy.s.sol -f [network] --verify --broadcast
```
