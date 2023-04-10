# Properties of scWETH

## Overview of the scWETH

The scWETH contract inherits the properties of ERC-4626 which is a standard that streamlines and standardizes the technical specifications of yield-bearing vaults. This standard offers a standardized API for yield-bearing vaults that are represented by tokenized shares of a single ERC-20 token. Additionally, ERC-4626 includes an optional extension for vaults that use ERC-20 tokens, providing basic features such as token deposit, withdrawal, and balance inquiry.

It has mainly the following state constants:
* `asset` (type `address`), the underlying ERC20 asset that is invested into the strategy
* `KEEPER_ROLE` (type `bytes32`), the `keeper` role
* `DEFAULT_ADMIN_ROLE` (type `bytes32`), the `admin` role
* `aavePool` (type `IPool`), the Aave WstETH pool
* `aToken` (type `IAToken`), the Aave WstWETH AToken
* `variableDebtToken` (type `ERC20`), the Aave's VariableDebtToken
* `curvePool` (type `ICurvePool`), the CurvePool contract
* `stEth` (type `ILido`), the Lido stETH contract
* `wstETH` (type `IwstETH`), the IwstETH contract
* `weth` (type `WETH`), the WETH contract
* `stEThToEthPriceFeed` (type `AggregatorV3Interface`), the AggregatorV3 contract
* `balancerVault` (type `IVault`), the balancer vault contract
* `name` (type `string`), the name of the token which represents shares of the vault
* `symbol` (type `string`), the symbol of the token which represents shares of the vault
* `totalSupply` (type `uint256`), the total supply of the shares of the vault
* `totalInvested` (type `uint256`), the total amount of asset invested into the strategy
* `totalProfit` (type `uint256`), the total profit in the underlying asset made by the strategy
* `targetLtv` (type `uint256`), the target LTV
* `slippageTolerance` (type `uint256`), the slippage tolerance when trading assets
* `performanceFee` (type `uint256` and initial value `0.2e18`), the performance fee used by the strategy
* `floatPercentage` (type `uint256` and initial value `0.01e18`), the float percentage used by the strategy
* `treasury` (type `address`), the treasury where fees go to
* `nonces` (type `address to uint256`), mapping given for replay protection

It has the following external/functions that change state variables:
* `setPerformanceFee(uint256 newPerformanceFee) onlyRole(DEFAULT_ADMIN_ROLE)` sets the `performanceFee` to `newPerformanceFee` as long as the `newPerformanceFee` is less than or equal to `1e18`
* `setFloatPercentage(uint256 newFloatPercentage) onlyRole(DEFAULT_ADMIN_ROLE)` sets the `floatPercentage` to `newFloatPercentage` as long as the `newFloatPercentage` is less than or equal to `1e18`
* `setTreasury(address newTreasury) onlyRole(DEFAULT_ADMIN_ROLE)` sets the `treasury` to `newTreasury` as long as the `newTreasury` is not the zero address
* `deposit(uint256 assets, address receiver) returns (uint256 shares)` deposits `assets` of underlying tokens into the vault and grants ownership of `shares` to `receiver`
* `mint(uint256 shares, address receiver) returns (uint256 assets)` mints exactly `shares` vault shares to `receiver` by depositing assets of underlying tokens
* `withdraw(uint256 assets, address receiver, address owner) returns (uint256 shares)` burns `shares` from `owner` and send exactly `assets` token from the vault to `receiver`
* `redeem(uint256 shares, address receiver, address owner) returns (uint256 assets)` redeems a specific number of `shares` from `owner` and send `assets` of underlying token from the vault to `receiver`
* `approve(address spender, uint256 amount) returns (bool)` returns `true` if it can sets the `amount` as the allowance of `spender` over the caller’s tokens
* `transfer(address to, uint256 amount) returns (bool)` returns `true` if it can move `amount` tokens from the caller’s `account` to `recipient`
* `transferFrom(address from, address to, uint256 amount) returns (bool)` returns `true` if it can move amount tokens from `sender` to `recipient` using the allowance mechanism, deducing the `amount` from the caller’s allowance
* `grantRole(bytes32 role, address account) onlyRole(getRoleAdmin(role))` grants `role` to `account`
* `revokeRole(bytes32 role, address account) onlyRole(getRoleAdmin(role))` revokes `role` from `account`
* `renounceRole(bytes32 role, address account)` revokes `role` from the calling `account`
* `withdrawToVault(uint256 amount) onlyRole(KEEPER_ROLE)` withdraw assets from strategy to the vault
* `harvest() onlyRole(KEEPER_ROLE)` harvest any unclaimed rewards
* `applyNewTargetLtv(uint256 _targetLtv) onlyRole(KEEPER_ROLE)` change leverage ratio
* `receiveFlashLoan(address[] null, uint256[] amounts, uint256[] null, bytes userData)`, flashloan callback

It has the following view functions, which do not change state:
* `getCollateral() returns (uint256)` returns total wstETH supplied as collateral (in ETH terms)
* `getDebt() returns (uint256)` returns total ETH borrowed
* `getLeverage() returns (uint256)` returns the net leverage that the strategy is using right now (1e18 = 100%)
* `getLtv() returns (uint256 ltv)` returns the net LTV at which we have borrowed till now (1e18 = 100%)
* `getMaxLtv() returns (uint256)` returns the max loan to value(ltv) ratio for borrowing eth on Aavev3 with wsteth as collateral for the flashloan (1e18 = 100%)
* `wstEthToEth(uint256 wstEthAmount) returns (uint256 ethAmount)` returns ETH amount if trading wstETH for ETH
* `totalAssets() returns (uint256)` returns the `total amount` of underlying assets held by the vault
* `convertToShares(uint256 assets) returns (uint256 shares)` returns the amount of `shares` that would be exchanged by the vault for the amount of `assets` provided
* `convertToAssets(uint256 shares) returns (uint256 assets)` returns the amount of `assets` that would be exchanged by the vault for the amount of `shares` provided
* `previewDeposit(uint256 assets) returns (uint256)` allows users to simulate the effects of their deposit at the current block
* `previewMint(uint256 shares) returns (uint256)` allows users to simulate the effects of their mint at the current block
* `previewWithdraw(uint256 assets) returns (uint256)` allows users to simulate the effects of their withdrawal at the current block
* `previewRedeem(uint256 shares) returns (uint256)` allows users to simulate the effects of their redemption at the current block
* `maxDeposit(address receiver) returns (uint256)` returns the maximum amount of underlying assets that can be deposited in a `single deposit` call by the `receiver`
* `maxMint(address receiver) returns (uint256)` returns the maximum amount of shares that can be minted in a `single mint` call by the `receiver`
* `maxWithdraw(address owner) returns (uint256)` returns the maximum amount of underlying assets that can be withdrawn from the `owner` balance with a `single withdraw` call
* `maxRedeem(address owner) returns (uint256)` returns the maximum amount of shares that can be redeem from the `owner` balance through a `redeem` call
* `hasRole(bytes32 role, address account) returns (bool)` returns `true` if `account` has been granted `role`
* `getRoleAdmin(bytes32 role) returns (bytes32)` returns the `admin role` that controls `role`

## Properties

| No. | Property  | Category | Priority | Specified | Verified | Report |
| ---- | --------  | -------- | -------- | -------- | -------- | -------- |
| 1 | `convertToShares(uint256 assets)` should return the same value for a given parameter regardless of the caller | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/74b44ab3cd9a4e23abc9360493fff135?anonymousKey=0b5ae3042001344f84ac790a95565eadfde2fc5b) |
| 2 | `convertToShares(assets) >= previewDeposit(assets)`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/4126cdaff05b4660bdccc91ec7b4374b?anonymousKey=317b8908167073ca15b14e1685ef63ee2f5948ca) |
| 3 | `convertToShares(uint256 assets)` should round down towards 0 | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/2b939cdcc8ff4617a604d8b47c855f74?anonymousKey=b3779a5dda77930fee0f651ddfcfce0acacef7ae) |
| 4 | share price should be maintained after non-core functions | high level | high | Y | N (timeout) | [Link]() |
| 5 | share price should be maintained after mint | high level | high | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/39fcd2ff3875431cb79d38f92755eeb1?anonymousKey=2c3dd8897164eb34a608cd06e18613f901750514) |
| 6 | `convertToAssets(uint256 shares)` should return the same value for a given parameter regardless of the caller | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/c0113b7e54a34eb08725ec4e44997e77?anonymousKey=63623e30d872a5c8a34ebcfbd77e2b50904d8bbb) |
| 7 | `convertToAssets(shares) <= previewMint(shares)`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/3fb4767676da4e8bb1381aa38b0041d5?anonymousKey=29bca51361e1cdbabc033381a637d50e4b76b7c5) |
| 8 | `convertToAssets(uint256 shares)` should round down towards 0 | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/c40661a52907490ea05427df9d071f41?anonymousKey=5c2ae38f9ba7118694f5d866677cdb10c373a599) |
| | `maxDeposit(address) == 2^256 - 1`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/14e1f77cd6d04579b1888a58984e4a9d?anonymousKey=19a860505b52224804f2c808ba1eb867d163cb3b)|
| | `maxMint(address) == 2^256 - 1`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/bc013b8c033340d6843bec295faba65a?anonymousKey=af7f3e9a87635a80db88e5898c936bf179ebbd7f)|
| 11 | `previewDeposit(assets) <= deposit(assets, receiver)`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/383a382edabf4e508d99b1a1cf786c72?anonymousKey=45be0317fadbceebf2b68846eca6e4686b696c10) |
| 12 | `previewMint(shares) >= mint(shares, receiver)`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/a69a7e44ef814962881e9f09856561d5?anonymousKey=f276bb87cd1e18ac4fd6e43be08f45a7d07c61f5) |
| 13 | `previewRedeem(shares) <= redeem(shares, receiver, owner)`  | high level | high | Y | N (timeout) | [Link]() |
| 14 | `deposit(uint256 assets, address receiver) returns (uint256 shares)` mints exactly `shares` Vault shares to `receiver` by depositing exactly `assets` of underlying tokens | variable transition | high | Y | Y | [Link](https://prover.certora.com/output/52311/25b97015f52140859a9eb17fa8509283?anonymousKey=a21f03244f9e06723f5d3d9be067c01010418749)  |
| 15 | `deposit(uint256 assets, address receiver) returns (uint256 shares)` must revert if all of `assets` cannot be deposited (to complete) | unit test | Y | Y | [Link](https://prover.certora.com/output/52311/c3ad818ebb42432288b4f3eb8c819e2c?anonymousKey=20e7bdd174ff258296cbeeba700fee8e2e31f1a0)  |
| 16 | `mint(uint256 shares, address receiver) returns (uint256 assets)` mints exactly `shares` Vault shares to `receiver` | variable transition | high | Y | Y | [Link](https://prover.certora.com/output/52311/6c9171db285841da9ee3b8627bc81318?anonymousKey=dc3283a3f1e5e4a2e1f16719fd0b087926757b52) |
| 17 | `mint(uint256 shares, address receiver) returns (uint256 assets)` must revert if the minter has not enough assets | unit test | high | Y | Y | [Link](https://prover.certora.com/output/52311/ea1b64008dd24be08166cd72c5151085?anonymousKey=a4ce6442674c0704aca24a6aeb9b530d3fb7af17)  |
| 18 | `withdraw(uint256 assets, address receiver, address owner) returns (uint256 shares)` must revert | unit test | high | Y | Y | [Link](https://prover.certora.com/output/52311/10fd791302c44ad793478d9dd810f006?anonymousKey=126eaa1617102b52fc2cef6f0eeba351822eef41)  |
| 19 | `redeem(uint256 shares, address receiver, address owner) returns (uint256 assets)` must burn exactly `shares` from `owner` and sends assets of underlying tokens to `receiver` | variable transition | high | Y | N (timeout) | [Link]()  |
| 20 | `redeem(uint256 shares, address receiver, address owner) returns (uint256 assets)` must revert if all of `shares` cannot be redeemed | unit test | high | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/101aa6cb10204663863e8a9cc1f87fac?anonymousKey=ddca0395a4d8cc4e746656e4d0a9eedd7c9a23cc)  |
| 21 | `applyNewTargetLtv(uint256 _targetLtv)` change leverage ratio | variable transition | high | Y | Y | [Link](https://prover.certora.com/output/52311/395b8bd9f70f4d1cabeb8c8afb8aadb9?anonymousKey=1ecdc8d32bbb9d56763a05136cf1e63507539774) |
| 22 | `applyNewTargetLtv(uint256 _targetLtv)` should revert if `_targetLtv` exceeds `getMaxLtv()` | unit test | medium | Y | Y | [Link](https://prover.certora.com/output/52311/a4709f1775e7477daf0c8af49a26f3fa?anonymousKey=105f9196442d77e1cd3e0a52656f6c863de09595) |
| 23 | `receiveFlashLoan(address[] null, uint256[] amounts, uint256[] null, bytes userData)` should revert if the caller is not balancerVault | unit test | high | Y | Y | [Link](https://prover.certora.com/output/52311/a2750e852a5c4f978472c8c869cfefda?anonymousKey=915bebf4087deef4ad4241bfdd0df42c64eff455) |
| 24 | `setPerformanceFee(uint256 newPerformanceFee)` should update the state variable `performanceFee` with the value provided by `newPerformanceFee`, as long as `newPerformanceFee` is less than or qual to `1e18` | variable transition | medium | Y | Y | [Link](https://prover.certora.com/output/52311/a493213f049d4591882f4f8ee2e8285e?anonymousKey=48c273190e12b959f74042fb8e18182277611564) |
| 25 | `setPerformanceFee(uint256 newPerformanceFee)` should revert if `newPerformanceFee` is greater than `1e18` | unit test | medium | Y | Y | [Link](https://prover.certora.com/output/52311/295c4c275dfa455eb73e40cf8d0f6d02?anonymousKey=e3c72e4e60df5321a66bc3357aac893ef2ae9bde) |
| 26 | `setFloatPercentage(uint256 newFloatPercentage)` should update the state variable `floatPercentage` with the value provided by `newFloatPercentage`, as long as `newFloatPercentage` is less than or qual to `1e18` | variable transition | medium | Y | Y | [Link](https://prover.certora.com/output/52311/8c3ea2b54da54b2dab822c4832f11f87?anonymousKey=980008b8288bafce5c59fd4feb3bf6b6bc9a2f25) |
| 27 | `setFloatPercentage(uint256 newFloatPercentage)` should revert if `newFloatPercentage` is greater than `1e18` | unit test | medium | Y | Y | [Link](https://prover.certora.com/output/52311/7c304730f33b4525bd7397e9a29884ef?anonymousKey=a3709b48a8f2abb96f93acf0c237566810f1652f)|
| 28 | `setTreasury(address newTreasury)` should update the state variable `treasury` with the value provided by `newTreasury`, as long as `newTreasury` is not the address zero | variable transition | medium | Y | Y | [Link](https://prover.certora.com/output/52311/d2738822ff6244598059a44d1645c7b3?anonymousKey=c20ad77d118a13edc8b8f986d18f3b3ba71141c8) |
| 29 | `setTreasury(address newTreasury)` should revert if `newTreasury` is the address zero | unit test | medium | Y | Y | [Link](https://prover.certora.com/output/52311/841cfbe785cf4319ba3470ac645a16f7?anonymousKey=e33078ce7d6ecf486a124475fcd58ac3a7b58565) |