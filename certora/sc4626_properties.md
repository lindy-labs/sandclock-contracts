# Properties of SC4626

## Overview of the SC4626

The SC4626 contract inherits the properties of ERC-4626 which is a standard that streamlines and standardizes the technical specifications of yield-bearing vaults. This standard offers a standardized API for yield-bearing vaults that are represented by tokenized shares of a single ERC-20 token. Additionally, ERC-4626 includes an optional extension for vaults that use ERC-20 tokens, providing basic features such as token deposit, withdrawal, and balance inquiry.

The SC4626 contract has the following external/public functions that change state variables:
* `function setPerformanceFee(uint256 newPerformanceFee) external onlyRole(DEFAULT_ADMIN_ROLE)` sets the `performanceFee` to `newPerformanceFee` as long as the `newPerformanceFee` is less than or equal to `1e18`
* `function setFloatPercentage(uint256 newFloatPercentage) external onlyRole(DEFAULT_ADMIN_ROLE)` sets the `floatPercentage` to `newFloatPercentage` as long as the `newFloatPercentage` is less than or equal to `1e18`
* `function setTreasury(address newTreasury) external onlyRole(DEFAULT_ADMIN_ROLE)` sets the `treasury` to `newTreasury` as long as the `newTreasury` is not the zero address
* `function deposit(uint256 assets, address receiver) public returns (uint256 shares)` deposits `assets` of underlying tokens into the vault and grants ownership of `shares` to `receiver`
* `function mint(uint256 shares, address receiver) public returns (uint256 assets)` mints exactly `shares` vault shares to `receiver` by depositing assets of underlying tokens
* `function withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares)` burns `shares` from `owner` and send exactly `assets` token from the vault to `receiver`
* `function redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets)` redeems a specific number of `shares` from `owner` and send `assets` of underlying token from the vault to `receiver`
* `function depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external` performs a `deposit` if it is permitted
* `function approve(address spender, uint256 amount) public returns (bool)` returns `true` if it can sets the `amount` as the allowance of `spender` over the caller’s tokens
* `function transfer(address to, uint256 amount) public returns (bool)` returns `true` if it can move `amount` tokens from the caller’s `account` to `recipient`
* `function transferFrom(address from, address to, uint256 amount) public returns (bool)` returns `true` if it can move amount tokens from `sender` to `recipient` using the allowance mechanism, deducing the `amount` from the caller’s allowance
    permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
* `function grantRole(bytes32 role, address account) public onlyRole(getRoleAdmin(role))` grants `role` to `account`
* `function revokeRole(bytes32 role, address account) public onlyRole(getRoleAdmin(role))` revokes `role` from `account`
* `function renounceRole(bytes32 role, address account)` revokes `role` from the calling `account`
* `function depositIntoStrategy() external` accesses control not needed, this is only separate to save gas for users depositing, ultimately controlled by float 
* `function harvest(uint256 _lqtyAmount, bytes calldata _lqtySwapData, uint256 _ethAmount, bytes calldata _ethSwapData) external onlyRole(KEEPER_ROLE)` harvest any unclaimed rewards and swaps LQTY with LUSD

The SC4626 has the following state variables
* `asset` (type `address`), the underlying ERC20 asset of the strategy
* `name` (type `string`), the name of the strategy
* `symbol` (type `string`), the symbol of the strategy
* `totalInvested` (type `uint256`), the Total Invested
* `totalProfit` (type `uint256`), the Total Pofit
* `stabilityPool` (type `address`), the Liquity Stability Pool
* `lusd2eth` (type `address`), the LUSD to ETH token
* `lqty` (type `address`), the LQTY token
* `performanceFee` (type `uint256` and initial value `0.2e18`), the performance fee used by the strategy
* `floatPercentage` (type `uint256` and initial value `0.01e18`), the float percentage used by the strategy
* `treasury` (type `address`), the treasury where fees go to
* `nonces` (type `address to uint256`), mapping given for replay protection

The SC4626 has the following state constants
* `KEEPER_ROLE` (type `bytes32`), the `keeper` `role`
* `DEFAULT_ADMIN_ROLE` (type `bytes32`), the `admin` `role`

It has the following view functions, which do not change state
* `function totalAssets() public view returns (uint256)` returns the `total amount` of underlying assets held by the vault
* `function convertToShares(uint256 assets) public view returns (uint256 shares)` returns the amount of `shares` that would be exchanged by the vault for the amount of `assets` provided
* `function convertToAssets(uint256 shares) public view returns (uint256 assets)` returns the amount of `assets` that would be exchanged by the vault for the amount of `shares` provided
* `function previewDeposit(uint256 assets) public view returns (uint256)` allows users to simulate the effects of their deposit at the current block
* `function previewMint(uint256 shares) public view returns (uint256)` allows users to simulate the effects of their mint at the current block
* `function previewWithdraw(uint256 assets) public view returns (uint256)` allows users to simulate the effects of their withdrawal at the current block
* `function previewRedeem(uint256 shares) public view returns (uint256)` allows users to simulate the effects of their redeemption at the current block
* `function maxDeposit(address receiver) public view returns (uint256)` returns the maximum amount of underlying assets that can be deposited in a `single deposit` call by the `receiver`
* `function maxMint(address receiver) public view returns (uint256)` returns the maximum amount of shares that can be minted in a `single mint` call by the `receiver`
* `function maxWithdraw(address owner) public view returns (uint256)` returns the maximum amount of underlying assets that can be withdrawn from the `owner` balance with a `single withdraw` call
* `function maxRedeem(address owner) public view returns (uint256)` returns the maximum amount of shares that can be redeem from the `owner` balance through a `redeem` call
* `function DOMAIN_SEPARATOR() returns (bytes32)` returns the domain separator of the underlying protocol
* `supportsInterface(bytes4 interfaceId) returns (bool)` returns `true` if this contract implements the interface defined by `interfaceId`
* `function hasRole(bytes32 role, address account) returns (bool)` returns `true` if `account` has been granted `role`
* `function getRoleAdmin(bytes32 role) returns (bytes32)` returns the `admin role` that controls `role`


## Properties

| No. | Property  | Category | Priority | Specified | Verified | Report |
| ---- | --------  | -------- | -------- | -------- | -------- | -------- |
|  | `setPerformanceFee(uint256 newPerformanceFee)` should update the state variable `performanceFee` with the value provided by `newPerformanceFee`, as long as `newPerformanceFee` is less than or qual to `1e18` | medium | N | N | []()  |
|  | `setFloatPercentage(uint256 newFloatPercentage)` should update the state variable `floatPercentage` with the value provided by `newFloatPercentage`, as long as `newFloatPercentage` is less than or qual to `1e18` | medium | N | N | []()  |
|  | `setTreasury(address newTreasury)` should update the state variable `treasury` with the value provided by `newTreasury`, as long as `newTreasury` is not the address zero | medium | N | N | []()  |
|  | `depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)` should deposit `amount` in the address of the message sender, as long as it has the right permission | high | N | N | []()  |
|  | `setPerformanceFee(uint256 newPerformanceFee)` should revert if `newPerformanceFee` is greater than `1e18` | unit test | N | N | []()  |
|  | `setFloatPercentage(uint256 newFloatPercentage)` should revert if `newFloatPercentage` is greater than `1e18` | unit test | N | N | []()  |
|  | `setTreasury(address newTreasury)` should revert if `newTreasury` is the address zero | unit test | N | N | []()  |
|  | `depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)` should revert if it does not have the right permission | unit test | N | N | []()  |
|  | `function deposit(uint256 assets, address receiver) public returns (uint256 shares)` mints exactly `shares` Vault shares to `receiver` by depositing exactly `assets` of underlying tokens | high level | N | N | []()  |
|  | `function deposit(uint256 assets, address receiver) public returns (uint256 shares)` must revert if all of `assets` cannot be deposited (to complete) | unit test | N | N | []()  |
|  | `mint(uint256 shares, address receiver) public returns (uint256 assets)` mints exactly `shares` Vault shares to `receiver` | high level | N | N | []()  |
|  | `mint(uint256 shares, address receiver) public returns (uint256 assets)` must revert if all of `shares` cannot be minted | unit test | N | N | []()  |
|  | `withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares)` must burn `shares` from `owner` and sends exactly `assets` of underlying tokens to `receiver` | high level | N | N | []()  |
|  | `withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares)` must revert if all of `assets` cannot be withdrawn | unit test | N | N | []()  |
|  | `redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets)` must burn exactly `shares` from `owner` and sends assets of underlying tokens to `receiver` | high level | N | N | []()  |
|  | `redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets)` must revert if all of `shares` cannot be redeemed | unit test | N | N | []()  |
