# Properties of scUSDC

## Overview of the scUSDCv2

The scUSDC contract inherits the properties of ERC-4626 which is a standard that streamlines and standardizes the technical specifications of yield-bearing vaults. This standard offers a standardized API for yield-bearing vaults that are represented by tokenized shares of a single ERC-20 token. Additionally, ERC-4626 includes an optional extension for vaults that use ERC-20 tokens, providing basic features such as token deposit, withdrawal, and balance inquiry.

It has mainly the following state constants:
* `asset` (type `address`), the underlying ERC20 asset that is invested into the strategy
* `DEFAULT_ADMIN_ROLE` (type `bytes32`), the `admin` `role`
* `KEEPER_ROLE (type `bytes32`), the `keeper` `role`
* `wstETH` (type `IwstETH`), the IwstETH contract
* `weth` (type `WETH`), the WETH contract
* `usdc` (type `ERC20`), the ERC20 address
* `aUsdc` (type `IAToken`), the aave `aEthUSDC` token
* `dWeth` (type `ERC20`), the `ERC20` token
* `usdcToEthPriceFeed` (type `AggregatorV3Interface`), the AggregatorV3 contract
* `balancerVault` (type `IVault`), the balancer vault for flashloans
* `swapRouter` (type `ISwapRouter`), the Uniswap V3 router
* `scWETH` (type `ERC4626`), the leveraged (w)eth vault

It has mainly the following state variables:
* `name` (type `string`), the name of the token which represents shares of the vault
* `symbol` (type `string`), the symbol of the token which represents shares of the vault
* `totalSupply` (type `uint256`), the total supply of the shares of the vault

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
| 1 |  | high level | high | N | N | [Link]() |
