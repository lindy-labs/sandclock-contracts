# Properties of scUSDCv2

## Overview of the scUSDCv2

The v2 vault offers users the opportunity to generate interest on their USDC deposits by engaging in leveraged WETH staking. Utilizing various lending markets, this vault maximizes yield on USDC deposits while simultaneously borrowing WETH for staking purposes.

It has mainly the following state constants:
* `weth`(type `WETH`) (value `WETH(payable(C.WETH))`), ;
* `balancerVault` (type `IVault`) (value `IVault(C.BALANCER_VAULT)`), Balancer vault for flashloans;

It has mainly the following state variables:
* `scWETH` (type `ERC4626`), leveraged (w)eth vault;
* `priceConverter` (type `PriceConverter`), price converter contract;
* `swapper` (type `Swapper`), swapper contract for facilitating token swaps;
* `protocolAdapters` (type `EnumerableMap.UintToAddressMap`), mapping of IDs to lending protocol adapter contracts;
* `zeroExSwapWhitelist`(type `mapping(ERC20 => bool)`), mapping for the tokenOuts allowed during zeroExSwap;

It has the following external/functions that change state variables:
* `function rebalance(bytes[] calldata _callData) external`, Rebalance the vault's positions/loans in multiple lending markets;
* `function reallocate(uint256 _flashLoanAmount, bytes[] calldata _callData) external`, Reallocate collateral & debt between lending markets, ie move debt and collateral positions from one lending market to another;
* `function sellProfit(uint256 _usdcAmountOutMin) external`, Sells WETH profits (swaps to USDC);
* `function exitAllPositions(uint256 _endUsdcBalanceMin) external`, Emergency exit to disinvest everything, repay all debt and withdraw all collateral to the vault;
* `function receiveFlashLoan(address[] calldata, uint256[] calldata _amounts, uint256[] calldata _feeAmounts, bytes calldata _data) external`, Handles flashloan callbacks;
* `function supply(uint256 _adapterId, uint256 _amount) external`, Supply USDC assets to a lending market;
* `function borrow(uint256 _adapterId, uint256 _amount) external`, Borrow WETH from a lending market;
* `function repay(uint256 _adapterId, uint256 _amount) external`, Repay WETH to a lending market;
* `function withdraw(uint256 _adapterId, uint256 _amount) external`, Withdraw USDC assets from a lending market;
* `function disinvest(uint256 _amount) external`, Withdraw WETH from the staking vault (scWETH);
* `function whiteListOutToken(ERC20 _token, bool _value) external`, whitelist (or cancel whitelist) a token to be swapped out using zeroExSwap;
* `function setSwapper(Swapper _newSwapper) external`, Set the swapper contract used for executing token swaps;
* `function addAdapter(IAdapter _adapter) external`, Add a new protocol adapter to the vault;
* `function removeAdapter(uint256 _adapterId, bool _force) external`, Remove a protocol adapter from the vault. Reverts if the adapter is in use unless _force is true.
* `function claimRewards(uint256 _adapterId, bytes calldata _callData) external`, Claim rewards from a lending market;
* `function zeroExSwap(ERC20 _tokenIn, ERC20 _tokenOut, uint256 _amount, bytes calldata _swapData, uint256 _assetAmountOutMin) external`, Sell any token for the "asset" token on 0x exchange.


It has the following view functions, which do not change state:
* `function totalAssets() public view override returns (uint256)`, total claimable assets of the vault in USDC;
* `function usdcBalance() public view returns (uint256)`, Returns the USDC balance of the vault;
* `function getCollateral(uint256 _adapterId) external view returns (uint256)`, Returns the USDC supplied as collateral in a lending market;
* `function totalCollateral() public view returns (uint256 total)`, Returns the total USDC supplied as collateral in all lending markets;
* `function getDebt(uint256 _adapterId) external view returns (uint256)`, Returns the WETH borrowed from a lending market;
* `function totalDebt() public view returns (uint256 total)`, Returns the total WETH borrowed in all lending markets;
* `function wethInvested() public view returns (uint256)`, Returns the amount of WETH invested (staked) in the leveraged WETH vault;
* `function getProfit() public view returns (uint256)`, Returns the amount of profit (in WETH) made by the vault;
* `function isSupported(uint256 _adapterId) public view returns (bool)`, Check if a lending market adapter is supported/used;
* `function getAdapter(uint256 _adapterId) external view returns (address adapter)`, returns the adapter address given the adapterId (only if the adaapterId is supported else returns zero address);
* `function isTokenWhitelisted(ERC20 _token) external view returns (bool)`, returns whether a token is whitelisted to be swapped out using zeroExSwap or not;

## Properties

| No. | Property  | Category | Priority | Specified | Verified | Report |
| ---- | --------  | -------- | -------- | -------- | -------- | -------- |
|  | `addAdapter(_adapter)` should update the state variable `protocolAdapters` with the parameter provided by `_adapter`, as long as `_adapter` is not already present in `protocolAdapters` | variable transition | medium | Y | Y | [Link]() |
|  | `addAdapter(_adapter)` should revert if `_adapter` is already present in `protocolAdapters` | unit test | medium | Y | Y | [Link]() |
|  | `whiteListOutToken(ERC20 _token, bool _value)` should update the state variable `zeroExSwapWhitelist` with the parameters provided by `_token` and `_value`, as long as `_token` is not the address zero | variable transition | medium | Y | Y | [Link]() |
|  | `whiteListOutToken(ERC20 _token, bool _value)` should revert if `_token` is the address zero | unit test | medium | Y | Y | [Link]() |
|  | `setSwapper(Swapper _newSwapper)` should update the state variable `swapper` with the value provided by `_newSwapper`, as long as `_newSwapper` is not the address zero | variable transition | medium | Y | Y | [Link]() |
|  | `setSwapper(Swapper _newSwapper)` should revert if `_newSwapper` is the address zero | unit test | medium | Y | Y | [Link]() |
