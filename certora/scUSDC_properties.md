# Properties of scUSDC

## Overview of the scUSDC

The scUSDC contract inherits the properties of ERC-4626 which is a standard that streamlines and standardizes the technical specifications of yield-bearing vaults. This standard offers a standardized API for yield-bearing vaults that are represented by tokenized shares of a single ERC-20 token. Additionally, ERC-4626 includes an optional extension for vaults that use ERC-20 tokens, providing basic features such as token deposit, withdrawal, and balance inquiry.

It has mainly the following state constants:
* `asset` (type `address`), the underlying ERC20 asset that is invested into the strategy
* `DEFAULT_ADMIN_ROLE` (type `bytes32`), the `admin` `role`
* `KEEPER_ROLE (type `bytes32`), the `keeper` `role`
* `wstETH` (type `IwstETH`), the IwstETH contract
* `weth` (type `WETH`), the WETH contract
* `usdc` (type `ERC20`), the ERC20 address
* `aavePool` (type `IPool`), the main aave contract for interaction with the protocol
* `aavePoolDataProvider` (type ``), the aave protocol data provider
* `aUsdc` (type `IAToken`), the aave `aEthUSDC` token
* `dWeth` (type `ERC20`), the `ERC20` token
* `usdcToEthPriceFeed` (type `AggregatorV3Interface`), the AggregatorV3 contract
* `balancerVault` (type `IVault`), the balancer vault for flashloans
* `ethWstEthMaxLtv` (type `uint256`), the max ETH/wstETH LTV
* `targetLtv` (type `uint256`), the USDC / WETH target LTV
* `swapRouter` (type `ISwapRouter`), the Uniswap V3 router
* `xrouter` (type `address`), the 0x swap router
* `rebalanceMinimum` (type `uint256`), the minimum USDC balance
* `scWETH` (type `ERC4626`), the leveraged (w)eth vault

It has mainly the following state variables:
* `name` (type `string`), the name of the token which represents shares of the vault
* `symbol` (type `string`), the symbol of the token which represents shares of the vault
* `totalSupply` (type `uint256`), the total supply of the shares of the vault
* `slippageTolerance` (type `uint256`), the max slippage for swapping WETH -> USDC

It has the following external/functions that change state variables:
* `deposit(uint256 assets, address receiver) returns (uint256 shares)` deposits `assets` of underlying tokens into the vault and grants ownership of `shares` to `receiver`
* `mint(uint256 shares, address receiver) returns (uint256 assets)` mints exactly `shares` vault shares to `receiver` by depositing assets of underlying tokens
* `withdraw(uint256 assets, address receiver, address owner) returns (uint256 shares)` burns `shares` from `owner` and send exactly `assets` token from the vault to `receiver`
* `redeem(uint256 shares, address receiver, address owner) returns (uint256 assets)` redeems a specific number of `shares` from `owner` and send `assets` of underlying token from the vault to `receiver`
* `depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external` performs a `deposit` if it is permitted
* `approve(address spender, uint256 amount) returns (bool)` returns `true` if it can sets the `amount` as the allowance of `spender` over the caller’s tokens
* `transfer(address to, uint256 amount) returns (bool)` returns `true` if it can move `amount` tokens from the caller’s `account` to `recipient`
* `transferFrom(address from, address to, uint256 amount) returns (bool)` returns `true` if it can move amount tokens from `sender` to `recipient` using the allowance mechanism, deducing the `amount` from the caller’s allowance
* `permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)`, permit `spender` to spend `owner`'s ERC20 assets
* `grantRole(bytes32 role, address account) onlyRole(getRoleAdmin(role))` grants `role` to `account`
* `revokeRole(bytes32 role, address account) onlyRole(getRoleAdmin(role))` revokes `role` from `account`
* `renounceRole(bytes32 role, address account)` revokes `role` from the calling `account`
* `setSlippageTolerance(uint256 _slippageTolerance) external onlyAdmin` sets the slippage tolerance (`slippageTolerance`) to `_slippageTolerance` for swapping WETH to USDC on Uniswap
* `applyNewTargetLtv(uint256 _newTargetLtv) external onlyKeeper` applies a new target LTV (`newTargetLtv`) to `_newTargetLtv` and triggers a rebalance
* `rebalance() public` rebalances the vault's positions
* `exitAllPositions() external onlyAdmin` performs an emergency exit to release collateral if the vault is underwater
* `receiveFlashLoan(address[] memory, uint256[] memory amounts, uint256[] memory, bytes memory userData) external` handles the repayment and collateral release logic for flash loans, where `userData` Data is passed to the callback function

It has the following view functions, which do not change state:
* `totalCollateralSupplied() returns (uint256)` returns total wstETH supplied as collateral (in ETH terms)
* `totalDebt() returns (uint256)` returns total ETH borrowed
* `getLeverage() returns (uint256)` returns the net leverage that the strategy is using right now (1e18 = 100%)
* `getLtv() returns (uint256 ltv)` returns the net LTV at which we have borrowed till now (1e18 = 100%)
* `wstEthToEth(uint256 wstEthAmount) returns (uint256 ethAmount)` returns ETH amount if trading wstETH for ETH
* `totalAssets() returns (uint256)` returns the `total amount` of underlying assets held by the vault
* `convertToShares(uint256 assets) returns (uint256 shares)` returns the amount of `shares` that would be exchanged by the vault for the amount of `assets` provided
* `convertToAssets(uint256 shares) returns (uint256 assets)` returns the amount of `assets` that would be exchanged by the vault for the amount of `shares` provided
* `maxDeposit(address receiver) returns (uint256)` returns the maximum amount of underlying assets that can be deposited in a `single deposit` call by the `receiver`
* `maxMint(address receiver) returns (uint256)` returns the maximum amount of shares that can be minted in a `single mint` call by the `receiver`
* `maxWithdraw(address owner) returns (uint256)` returns the maximum amount of underlying assets that can be withdrawn from the `owner` balance with a `single withdraw` call
* `maxRedeem(address owner) returns (uint256)` returns the maximum amount of shares that can be redeem from the `owner` balance through a `redeem` call
* `DOMAIN_SEPARATOR() returns (bytes32)` returns the domain separator of the underlying protocol
* `supportsInterface(bytes4 interfaceId) returns (bool)` returns `true` if this contract implements the interface defined by `interfaceId`
* `hasRole(bytes32 role, address account) returns (bool)` returns `true` if `account` has been granted `role`
* `getRoleAdmin(bytes32 role) returns (bytes32)` returns the `admin role` that controls `role`
* `totalAssets() public view returns (uint256)` returns the `totalAssets`
* `getUsdcFromWeth(uint256 _wethAmount) public view returns (uint256)` returns the `USDC` for ETH from `WETH` given by `_wethAmount`
* `getWethFromUsdc(uint256 _usdcAmount) public view returns (uint256)` returns the `WETH` from `USDC` given `_usdcAmount`
* `getUsdcBalance() public view returns (uint256)` returns the `USDC` balance of the vault
* `getCollateral() public view returns (uint256)` Returns the total `USDC` supplied as collateral to `Aave`
* `getDebt() public view returns (uint256)` returns the total eth borrowed on Aave
* `getLtv() public view returns (uint256)` returns the net LTV at which we have borrowed untill now (1e18 = 100%)
* `getMaxLtv() public view returns (uint256)` returns the current max LTV for USDC / WETH loans on Aave

## Properties

| No. | Property  | Category | Priority | Specified | Verified | Report |
| ---- | --------  | -------- | -------- | -------- | -------- | -------- |
| 1 | `convertToShares(uint256 assets)` should return the same value for a given parameter regardless of the caller | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 2 | `convertToShares(assets) >= previewDeposit(assets)`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 3 | `convertToShares(uint256 assets)` should round down towards 0 | high level | high | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 4 | share price should be maintained after non-core functions | high level | high | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 5 | share price should be maintained after mint | high level | high | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 6 | `convertToAssets(shares) <= previewMint(shares)`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 7 | `convertToAssets(uint256 shares)` should round down towards 0 | high level | high | Y | N | [Link]() |
| 8 | `maxDeposit(address) == 2^256 - 1`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad)|
| 9 | `maxMint(address) == 2^256 - 1`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad)|
| 10 | `previewDeposit(assets) <= deposit(assets, receiver)`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 11 | `previewMint(shares) >= mint(shares, receiver)`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 12 | `previewWithdraw(assets) >= withdraw(assets, receiver, owner)`  | high level | high | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 13 | `previewRedeem(shares) <= redeem(shares, receiver, owner)`  | high level | high | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 14 | `deposit(uint256 assets, address receiver) returns (uint256 shares)` mints exactly `shares` Vault shares to `receiver` by depositing exactly `assets` of underlying tokens | variable transition | high | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad)  |
| 15 | `deposit(uint256 assets, address receiver) returns (uint256 shares)` must revert if all of `assets` cannot be deposited (to complete) | unit test | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad)  |
| 16 | `mint(uint256 shares, address receiver) returns (uint256 assets)` mints exactly `shares` Vault shares to `receiver` | variable transition | high | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 17 | `mint(uint256 shares, address receiver) returns (uint256 assets)` must revert if the minter has not enough assets | unit test | high | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad)  |
| 18 | `withdraw(uint256 assets, address receiver, address owner) returns (uint256 shares)` must burn `shares` from `owner` and sends exactly `assets` of underlying tokens to `receiver` | variable transition | high | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad)  |
| 19 | `withdraw(uint256 assets, address receiver, address owner) returns (uint256 shares)` must revert if all of `assets` cannot be withdrawn | unit test | high | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad)  |
| 20 | `redeem(uint256 shares, address receiver, address owner) returns (uint256 assets)` must burn exactly `shares` from `owner` and sends assets of underlying tokens to `receiver` | variable transition | high | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad)  |
| 21 | `redeem(uint256 shares, address receiver, address owner) returns (uint256 assets)` must revert if all of `shares` cannot be redeemed | unit test | high | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad)  |
| 22 | `changeLeverage(uint256 _targetLtv)` change leverage ratio | variable transition | high | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 23 | `changeLeverage(uint256 _targetLtv)` should revert if `_targetLtv` exceeds `ethWstEthMaxLtv` | unit test | medium | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 24 | `receiveFlashLoan(address[] null, uint256[] amounts, uint256[] null, bytes userData)` should revert if the caller is not balancerVault | unit test | high | Y | N (Unwinding loop) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 25 | `setPerformanceFee(uint256 newPerformanceFee)` should update the state variable `performanceFee` with the value provided by `newPerformanceFee`, as long as `newPerformanceFee` is less than or qual to `1e18` | variable transition | medium | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 26 | `setPerformanceFee(uint256 newPerformanceFee)` should revert if `newPerformanceFee` is greater than `1e18` | unit test | medium | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 27 | `setFloatPercentage(uint256 newFloatPercentage)` should update the state variable `floatPercentage` with the value provided by `newFloatPercentage`, as long as `newFloatPercentage` is less than or qual to `1e18` | variable transition | medium | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 28 | `setFloatPercentage(uint256 newFloatPercentage)` should revert if `newFloatPercentage` is greater than `1e18` | unit test | medium | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad)|
| 29 | `setTreasury(address newTreasury)` should update the state variable `treasury` with the value provided by `newTreasury`, as long as `newTreasury` is not the address zero | variable transition | medium | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 30 | `setTreasury(address newTreasury)` should revert if `newTreasury` is the address zero | unit test | medium | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 31 | `setSlippageTolerance(uint256 _newSlippageTolerance) external onlyAdmin` should update the state variable `slippageTolerance` with the value provided by `_newSlippageTolerance`, as long as `_newSlippageTolerance` is lesser than or equal to the constant `ONE` | variable transition | medium | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 32 | `setSlippageTolerance(uint256 _newSlippageTolerance) external onlyAdmin` should revert if `_newSlippageTolerance` is greater than the constant `ONE` | unit test | medium | Y | Y | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 33 | `applyNewTargetLtv(uint256 _newTargetLtv) external onlyKeeper` should update the state variable `targetLtv` with the value provided by `_newTargetLtv` and rebalance the Vault if `_newTargetLtv` is lesser than or equal to the maximum `LTV` | High level | High | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 34 | `applyNewTargetLtv(uint256 _newTargetLtv) external onlyKeeper` should revert if `_newTargetLtv` is greater than the maximum `LTV` | unit test | medium | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 35 | `rebalance()` should rebalance the vault's positions | High level | High | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 36 | `rebalance()` should do nothing if Ltv is 0 | Medium level | unit test | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 37 | `exitAllPositions()` should perform an emergency exit to release collateral if the vault is underwater | High level | High | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
| 38 | `exitAllPositions()` should revert if the invested value is greater than or equal to the debt | Medium level | unit test | Y | N (timeout) | [Link](https://prover.certora.com/output/52311/27d2b985d14d4a1bb7dc7d6da5f53048?anonymousKey=6f0e839ccb4b4ee2aaab067103d86963d3e8c0ad) |
