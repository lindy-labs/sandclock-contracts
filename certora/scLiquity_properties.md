# Properties of scLiquity

## Overview of the scLiquity

The scLiquity contract inherits the properties of ERC-4626 which is a standard that streamlines and standardizes the technical specifications of yield-bearing vaults. This standard offers a standardized API for yield-bearing vaults that are represented by tokenized shares of a single ERC-20 token. Additionally, ERC-4626 includes an optional extension for vaults that use ERC-20 tokens, providing basic features such as token deposit, withdrawal, and balance inquiry.

The scLiquity has mainly the following state constants
* `asset` (type `address`), the underlying ERC20 asset that is invested into the strategy
* `KEEPER_ROLE` (type `bytes32`), the `keeper` `role`
* `DEFAULT_ADMIN_ROLE` (type `bytes32`), the `admin` `role`

The scLiquity has mainly the following state variables
* `name` (type `string`), the name of the token which represents shares of the vault
* `symbol` (type `string`), the symbol of the token which represents shares of the vault
* `totalSupply` (type `uint256`), the total supply of the shares of the vault
* `totalInvested` (type `uint256`), the total amount of asset invested into the strategy
* `totalProfit` (type `uint256`), the total profit in the underlying asset made by the strategy
* `stabilityPool` (type `address`), the Liquity Stability Pool
* `lusd2eth` (type `address`), the LUSD to ETH price feed contract address
* `lqty` (type `address`), the LQTY token
* `performanceFee` (type `uint256` and initial value `0.2e18`), the performance fee used by the strategy
* `floatPercentage` (type `uint256` and initial value `0.01e18`), the float percentage used by the strategy
* `treasury` (type `address`), the treasury where fees go to
* `nonces` (type `address to uint256`), mapping given for replay protection

The scLiquity contract has the following external/public functions that change state variables:
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
* `function depositIntoStrategy() external` deposit floating asset into the strategy 
* `function harvest(uint256 _lqtyAmount, bytes calldata _lqtySwapData, uint256 _ethAmount, bytes calldata _ethSwapData) external onlyRole(KEEPER_ROLE)` harvest any unclaimed rewards, and swaps LQTY with LUSD, and reinvest the LUSD



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
|  | `convertToShares(uint256 assets)` should return the same value for a given parameter regardless of the caller | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae) |
|  | `convertToShares(assets) >= previewDeposit(assets)`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae) |
|  | `convertToShares(uint256 assets)` should round down towards 0 | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae) |
|  | `convertToAssets(uint256 shares)` should return the same value for a given parameter regardless of the caller | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae) |
|  | `convertToAssets(shares) <= previewMint(shares)`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae) |
|  | `convertToAssets(uint256 shares)` should round down towards 0 | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae) |
|  | `maxDeposit(address) == 2^256 - 1`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae) |
|  | `maxMint(address) == 2^256 - 1`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae) |
|  | `previewDeposit(assets) <= deposit(assets, receiver)`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae) |
|  | `previewMint(shares) >= mint(shares, receiver)`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae) |
|  | `previewWithdraw(assets) >= withdraw(assets, receiver, owner)`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae) |
|  | `previewRedeem(shares) <= redeem(shares, receiver, owner)`  | high level | high | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae) |
|  | `function deposit(uint256 assets, address receiver) public returns (uint256 shares)` mints exactly `shares` Vault shares to `receiver` by depositing exactly `assets` of underlying tokens | variable transition | high | Y | Y | [Link](https://prover.certora.com/output/52311/a417c4eebad14173b81e4c59be3e4369?anonymousKey=f91ecbec305f3cad05192627b715f08143183a5f)  |
|  | `function deposit(uint256 assets, address receiver) public returns (uint256 shares)` must revert if all of `assets` cannot be deposited (to complete) | unit test | Y | Y | [Link]()  |
|  | `mint(uint256 shares, address receiver) public returns (uint256 assets)` mints exactly `shares` Vault shares to `receiver` | variable transition | high | Y | Y | [Link](https://prover.certora.com/output/52311/93e7c51f1d72446bae7d7f6a65df101c?anonymousKey=fd149ac8abcef42e2361085f1b628384dbfbbb00)  |
|  | `mint(uint256 shares, address receiver) public returns (uint256 assets)` must revert if all of `shares` cannot be minted | unit test | high | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae)  |
|  | `withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares)` must burn `shares` from `owner` and sends exactly `assets` of underlying tokens to `receiver` | variable transition | high | Y | Y | [Link](https://prover.certora.com/output/52311/93e7c51f1d72446bae7d7f6a65df101c?anonymousKey=fd149ac8abcef42e2361085f1b628384dbfbbb00)  |
|  | `withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares)` must revert if all of `assets` cannot be withdrawn | unit test | high | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae)  |
|  | `redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets)` must burn exactly `shares` from `owner` and sends assets of underlying tokens to `receiver` | variable transition | high | Y | Y | [Link](https://prover.certora.com/output/52311/1c33ea168c8f4e46853d273e5bfa9af0?anonymousKey=ad3cb2132614d0826550e81123e54aa12eabe28f)  |
|  | `redeem(uint256 shares, address receiver, address owner) public returns (uint256 assets)` must revert if all of `shares` cannot be redeemed | unit test | high | Y | Y | [Link](https://prover.certora.com/output/52311/48da1c2a8f84493d9052ab5e9e68d6f8?anonymousKey=17d357366cbd9490a6679e23eafaea35206eb216)  |
|  | `setPerformanceFee(uint256 newPerformanceFee)` should update the state variable `performanceFee` with the value provided by `newPerformanceFee`, as long as `newPerformanceFee` is less than or qual to `1e18` | variable transition | medium | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae)  |
|  | `setFloatPercentage(uint256 newFloatPercentage)` should update the state variable `floatPercentage` with the value provided by `newFloatPercentage`, as long as `newFloatPercentage` is less than or qual to `1e18` | variable transition | medium | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae)  |
|  | `setTreasury(address newTreasury)` should update the state variable `treasury` with the value provided by `newTreasury`, as long as `newTreasury` is not the address zero | variable transition | medium | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae)  |
|  | `setPerformanceFee(uint256 newPerformanceFee)` should revert if `newPerformanceFee` is greater than `1e18` | unit test | medium | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae)  |
|  | `setFloatPercentage(uint256 newFloatPercentage)` should revert if `newFloatPercentage` is greater than `1e18` | unit test | medium | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae) |
|  | `setTreasury(address newTreasury)` should revert if `newTreasury` is the address zero | unit test | medium | Y | Y | [Link](https://prover.certora.com/output/52311/9d8b633eb8594ce496dd9d8389359f74?anonymousKey=7116474830420dfc91c9992c28f17bcd11f744ae)  |
