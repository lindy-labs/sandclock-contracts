# Properties of scWETHv2

## Overview of the scWETHv2

The scWETHv2 contract inherits the properties of ERC-4626 which is a standard that streamlines and standardizes the technical specifications of yield-bearing vaults. This standard offers a standardized API for yield-bearing vaults that are represented by tokenized shares of a single ERC-20 token. Additionally, ERC-4626 includes an optional extension for vaults that use ERC-20 tokens, providing basic features such as token deposit, withdrawal, and balance inquiry.

Using hevm, we prove properties about scWETHv2 as well as inherits some tests from the Dev team (not listed here, just in the test file).

It has mainly the following state constants:
* `stEth` (type `ILido`), the Lido stETH contract
* `wstETH` (type `IwstETH`), the IwstETH contract
* `weth` (type `WETH`), the WETH contract
* `totalSupply` (type `uint256`), the total supply of the shares of the vault
* `totalInvested` (type `uint256`), the total amount of asset invested into the strategy
* `totalProfit` (type `uint256`), the total profit in the underlying asset made by the strategy
* `slippageTolerance` (type `uint256`), the slippage tolerance when trading assets
* `performanceFee` (type `uint256` and initial value `0.2e18`), the performance fee used by the strategy
* `floatPercentage` (type `uint256` and initial value `0.01e18`), the float percentage used by the strategy
* `treasury` (type `address`), the treasury where fees go to
* `curvePool` (type `ICurvePool`), curve pool for ETH-stETH
* `balancerVault` (type `IVault`), balancer vault for flashloans
* `lendingManager` (type `LendingMarketManager`), external contract (Aave's lending pool)
* `oracleLib` (type `OracleLib`), external contract (bridge)


It has the following external/public functions that change state variables:
* `function setSlippageTolerance(uint256 newSlippageTolerance) external onlyAdmin` sets the slippage tolerance (`slippageTolerance`) to `_slippageTolerance` for curve swaps
* `function setMinimumFloatAmount(uint256 newFloatAmount) external onlyAdmin` sets `minimumFloatAmount` to `newFloatAmount`
* `setTreasury(address newTreasury) onlyRole(DEFAULT_ADMIN_ROLE)` sets the `treasury` to `newTreasury` as long as the `newTreasury` is not the zero address
* `function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets)` redeems a specific number of `shares` from `owner` and send `assets` of underlying token from the vault to `receiver`
* `function withdrawToVault(uint256 amount) external` withdraw assets from strategy to the vault
* `function swapTokens(bytes calldata swapData, address inToken, address outToken, uint256 amountIn, uint256 amountOutMin) external` swaps euler rewards to weth tokens (as well as others)
* `function investAndHarvest(uint256 totalInvestAmount, SupplyBorrowParam[] calldata supplyBorrowParams, bytes calldata wethToWstEthSwapData) external` invests funds into the strategy and harvest profits if any
* `function disinvest(RepayWithdrawParam[] calldata repayWithdrawParams, bytes calldata wstEthToWethSwapData) external` disinvests from lending markets in case of a loss
* `function reallocate( RepayWithdrawParam[] calldata from, SupplyBorrowParam[] calldata to, bytes calldata wstEthToWethSwapData, bytes calldata wethToWstEthSwapData, uint256 wstEthSwapAmount, uint256 wethSwapAmount) external` reallocates funds between protocols (without any slippage)
* `approve(address spender, uint256 amount) returns (bool)` returns `true` if it can sets the `amount` as the allowance of `spender` over the caller’s tokens
* `function deposit(address receiver) external payable returns (uint256 shares)` helper method to directly deposit ETH instead of weth
* `function receiveFlashLoan(address[] memory, uint256[] memory amounts, uint256[] memory, bytes memory userData)` flashloan callback

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

## Properties

| No. | Property  | Category | Priority | Specified | Verified |
| ---- | --------  | -------- | -------- | -------- | -------- |
| 1 | `setSlippageTolerance(uint256 newSlippageTolerance) external onlyAdmin` should update the state variable `slippageTolerance` with the value provided by `newSlippageTolerance`, as long as `newSlippageTolerance` is lesser than or equal to the constant `C.ONE` | variable transition | medium | Y | Y |
| 2 | `setSlippageTolerance(uint256 newSlippageTolerance) external onlyAdmin` should revert if `newSlippageTolerance` is greater than the constant `C.ONE` | unit test | medium | Y | Y |
| 3 | `setMinimumFloatAmount(uint256 newFloatAmount) external onlyAdmin` sets `minimumFloatAmount` to `newFloatAmount` | unit test | medium | Y | Y |
| 4 | `setTreasury(address newTreasury)` should update the state variable `treasury` with the value provided by `newTreasury`, as long as `newTreasury` is not the address zero | variable transition | medium | Y | Y |
| 5 | `setTreasury(address newTreasury)` should revert if `newTreasury` is the address zero | unit test | medium | Y | Y |
| 6 | `convertToAssets(uint256 shares)` should round down towards 0 | high level | high | Y | Y |
| 7 | `convertToShares(uint256 assets)` should round down towards 0 | high level | high | Y | Y |
| 8 | `convertToAssets(shares) <= previewMint(shares)`  | high level | high | Y | Y |
| 9 | `maxDeposit(address) == 2^256 - 1`  | high level | high | Y | Y |
| 10 | `maxMint(address) == 2^256 - 1`  | high level | high | Y | Y |
| 11 | `convertToShares(assets) >= previewDeposit(assets)`  | high level | high | Y | N |
| 12 | `deposit(uint256 assets, address receiver) returns (uint256 shares)` mints exactly `shares` Vault shares to `receiver` by depositing exactly `assets` of underlying tokens | variable transition | high | Y | N |
| 13 | `deposit(uint256 assets, address receiver) returns (uint256 shares)` must revert if all of `assets` cannot be deposited (to complete) | unit test | high | Y | N |
| 14 | `mint(uint256 shares, address receiver) returns (uint256 assets)` mints exactly `shares` Vault shares to `receiver` | variable transition | high | Y | N |
| 15 | `mint(uint256 shares, address receiver) returns (uint256 assets)` must revert if the minter has not enough assets | unit test | high | Y | N |
| 16 | `redeem(uint256 shares, address receiver, address owner) returns (uint256 assets)` must burn exactly `shares` from `owner` and sends assets of underlying tokens to `receiver` | variable transition | high | Y | N |
| 17 | `redeem(uint256 shares, address receiver, address owner) returns (uint256 assets)` must revert if all of `shares` cannot be redeemed | unit test | high | Y | N |
| 18 | `previewRedeem(shares) <= redeem(shares, receiver, owner)`  | high level | high | Y | N |
