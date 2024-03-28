import "erc20.spec";

using USDC as asset;
using WETH as weth;

methods {
    // state mofidying functions
    function mint(uint256 shares, address receiver) external returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function rebalance(bytes[] calldata _callData) external;
    function exitAllPositions(uint256) external;
    function totalCollateral() external;
    function sellProfit(uint256 _usdcAmountOutMin) external ;

    // view functions
    function convertToShares(uint256 assets) external returns (uint256) envfree;
    function convertToAssets(uint256 shares) external returns (uint256) envfree;
    function previewDeposit(uint256 assets) external returns (uint256) envfree;
    function totalAssets() external returns (uint256) envfree;
    function totalSupply() external returns (uint256) envfree;
    function previewDeposit(uint256 assets) external returns (uint256) envfree;
    function previewMint(uint256 shares) external returns (uint256) envfree;
    function previewWithdraw(uint256 assets) external returns (uint256) envfree;
    function previewRedeem(uint256 shares) external returns (uint256) envfree;
    function maxDeposit(address) external returns (uint256) envfree;
    function maxMint(address) external returns (uint256) envfree;
    function maxWithdraw(address owner) external returns (uint256) envfree;
    function maxRedeem(address owner) external returns (uint256) envfree;
    function usdcBalance() external returns (uint256) envfree;
    function floatPercentage() external returns (uint256) envfree;
    function wethInvested() external returns (uint256) envfree;
    function getProfit() external returns (uint256) envfree;
    function totalDebt() external returns (uint256) envfree;
    
    // erc20
    function asset.totalSupply() external returns (uint256) envfree;
    function asset.balanceOf(address) external returns (uint256) envfree;
    function weth.balanceOf(address) external returns (uint256) envfree;


    // state constants
    function _.getCollateral(address _account) external     => DISPATCHER(true);
    function _.getDebt(address _account) external           => DISPATCHER(true);
    function _.delegateCall(bytes) external                 => DISPATCHER(true);
    function _.balanceOf(address) external                  => DISPATCHER(true);

}

/*
    @Rule

    @Category: High level

    @Description:
        function convertToShares returns at least the same amount of shares than function previewDeposit
*/
/*rule convertToShares_gte_previewDeposit(uint256 assets) {
    assert convertToShares(assets) >= previewDeposit(assets);
}*/

/*
    @Rule

    @Category: High level

    @Description:
        function converToShares rounds down shares towards zero
*/
/*rule converToShares_rounds_down_towards_0(uint256 assets) {
    require (totalSupply() != 0);
    mathint lhs = assets * totalSupply() / totalAssets();
    mathint rhs = convertToShares(assets);
    assert lhs == rhs;
}*/

/*
    @Rule

    @Category: High level

    @Description:
        share price maintained after mint
*/
/*rule share_price_maintained_after_mint(uint256 shares, address receiver) { // Timed out
    env e;
    require e.msg.sender != currentContract;
    require receiver != currentContract;
    require e.msg.sender != receiver;

    uint256 _totalAssets = totalAssets();
    require _totalAssets == 0 <=> totalSupply() == 0;

    uint256 assets = mint(e, shares, receiver);
    mathint _totAssetsPlus = _totalAssets + assets;
    mathint assetTotSup = asset.totalSupply();
    require _totAssetsPlus <= assetTotSup; // avoid overflow
    
    assert assets == previewMint(shares);
}
*/

/*
    @Rule

    @Category: High level

    @Description:
        function convertToAssets returns at most the same amount of assets than function previewMint
*/
/*rule convertToAssets_lte_previewMint(uint256 shares) {
    assert convertToAssets(shares) <= previewMint(shares);
}*/

/*
    @Rule

    @Category: High level

    @Description:
        function convertToAssets rounds assets towards zero
*/
/*rule convertToAssets_rounds_down_towards_0(uint256 shares) {
    require totalSupply() != 0;
    mathint lhs = (shares * totalAssets()) / totalSupply();
    mathint rhs = convertToAssets(shares);
    assert lhs == rhs;
}*/

/*
    @Rule

    @Category: High level

    @Description:
        function maxDeposit returns the maximum expected value of a deposit
*/
/*rule maxDeposit_returns_correct_value(address receiver) {
    assert maxDeposit(receiver) == 2^256 - 1;
}*/

/*
    @Rule

    @Category: High level

    @Description:
        function maxMint returns the maximum expected value of a mint
*/
/*rule maxMint_returns_correct_value(address receiver) {
    assert maxMint(receiver) == 2^256 - 1;
}*/

/*
    @Rule

    @Category: High level

    @Description:
        function previewDeposit returns at most the same amount of assets than function deposit
*/
/*rule previewDeposit_lte_deposit(uint256 assets, address receiver) {
    env e;
    assert previewDeposit(assets) <= deposit(e, assets, receiver);
}*/

/*
    @Rule

    @Category: High level

    @Description:
        function previewMint returns at least the same amount of shares than function mint
*/
/*rule previewMint_gte_mint(uint256 shares, address receiver) {
    env e;
    assert previewMint(shares) >= mint(e, shares, receiver);
}*/

/*
    @Rule

    @Category: High level

    @Description:
        function previewWithdraw returns at least the same amount of assets than function withdraw
*/
/*rule previewWithdraw_gte_withdraw(uint256 assets, address receiver, address owner) {
    env e;
    assert previewWithdraw(assets) >= withdraw(e, assets, receiver, owner);
}*/

/*
    @Rule

    @Category: High level

    @Description:
        function previewRedeem returns at most the same amount of shares than function redeem
*/
/*rule previewRedeem_lte_redeem(uint256 shares, address receiver, address owner) {
    env e;
    assert previewRedeem(shares) <= redeem(e, shares, receiver, owner);
}*/

/*
    @Rule

    @Category: High level

    @Description:
        function deposit mints exactly shares Vault shares to receiver by depositing exactly assets of underlying tokens
*/
/*rule integrity_of_deposit(uint256 assets, address receiver) {
    env e;
    require e.msg.sender != currentContract;
    require receiver != currentContract;
    
    uint256 _userAssets = asset.balanceOf(e.msg.sender);
    uint256 _totalAssets = asset.balanceOf(currentContract);

    mathint lhs1 = _totalAssets + assets;
    mathint rhs1 = asset.totalSupply();
    require lhs1 <= rhs1;
    uint256 _receiverShares = balanceOf(receiver);

    uint256 shares = deposit(e, assets, receiver);

    mathint lhs2 = _receiverShares + shares;
    mathint rhs2 = totalSupply();
    require lhs2 <= rhs2;

    uint256 userAssets_ = asset.balanceOf(e.msg.sender);
    uint256 totalAssets_ = asset.balanceOf(currentContract);
    uint256 receiverShares_ = balanceOf(receiver);

    mathint lhs3 = _userAssets - assets;
    mathint rhs3 = userAssets_;
    assert lhs3 == rhs3;
    mathint lhs4 = _receiverShares + shares;
    mathint rhs4 = receiverShares_;
    assert lhs4 == rhs4;
    mathint lhs5 = _totalAssets + assets;
    mathint rhs5 = totalAssets_;
    assert lhs5 == rhs5;
}*/

/*
    @Rule

    @Category: High

    @Description:
        function mint mints exactly shares Vault shares to receiver
*/
/*rule integrity_of_mint(uint256 shares, address receiver) {
    env e;
    require e.msg.sender != currentContract;
    require receiver != currentContract;

    uint256 _userAssets = asset.balanceOf(e.msg.sender);
    uint256 _totalAssets = asset.balanceOf(currentContract);
    uint256 _receiverShares = balanceOf(receiver);
    mathint lhs1 = _receiverShares + shares;
    mathint rhs1 = totalSupply();
    require lhs1 <= rhs1;

    uint256 assets = mint(e, shares, receiver);
    mathint lhs2 = _totalAssets + assets;
    mathint rhs2 = asset.totalSupply();
    require lhs2 <= rhs2;

    uint256 userAssets_ = asset.balanceOf(e.msg.sender);
    uint256 totalAssets_ = asset.balanceOf(currentContract);
    uint256 receiverShares_ = balanceOf(receiver);

    mathint lhs3 = _userAssets - assets;
    mathint rhs3 = userAssets_;
    assert lhs3 == rhs3;
    mathint lhs4 = _totalAssets + assets;
    mathint rhs4 = totalAssets_;
    assert lhs4 == rhs4;
    mathint lhs5 = _receiverShares + shares;
    mathint rhs5 = receiverShares_;
    assert lhs5 == rhs5;
}*/

/*
    @Rule

    @Category: High

    @Description:
        function withdraw must burn shares from owner and sends exactly assets of underlying tokens to receiver
*/
/*rule integrity_of_withdraw(uint256 assets, address receiver, address owner) {
    env e;
    require e.msg.sender != currentContract;
    require receiver != currentContract;
    require e.msg.sender != owner;
    require owner != currentContract;
    require owner != receiver;

    uint256 _receiverAssets = asset.balanceOf(receiver);
    mathint lhs1 = _receiverAssets + assets;
    mathint rhs1 = asset.totalSupply();
    require lhs1 <= rhs1;
    uint256 _ownerShares = balanceOf(owner);
    uint256 _senderAllowance = allowance(owner, e.msg.sender);

    uint256 shares = withdraw(e, assets, receiver, owner);

    uint256 receiverAssets_ = asset.balanceOf(receiver);
    uint256 ownerShares_ = balanceOf(owner);
    uint256 senderAllowance_ = allowance(owner, e.msg.sender);

    mathint lhs2 = _receiverAssets + assets;
    mathint rhs2 = receiverAssets_;
    assert lhs2 == rhs2;
    mathint lhs3 = _ownerShares - shares;
    mathint rhs3 = ownerShares_;
    assert lhs3 == rhs3;
    mathint lhs4 = _senderAllowance - shares;
    mathint rhs4 = senderAllowance_;
    assert e.msg.sender != owner => 
        _senderAllowance == 2^256 -1 && senderAllowance_ == 2^256 -1 
        || lhs4 == rhs4;
}*/

/*
    @Rule

    @Category: High

    @Description:
        function redeem must burn exactly shares from owner and sends assets of underlying tokens to receiver
*/
/*rule integrity_of_redeem(uint256 shares, address receiver, address owner) {
    env e;
    uint256 _receiverAssets = asset.balanceOf(receiver);
    uint256 _totalAssets = asset.balanceOf(currentContract);
    uint256 _ownerShares = balanceOf(owner);
    uint256 _senderAllowance = allowance(owner, e.msg.sender);

    require e.msg.sender != currentContract;
    require receiver != currentContract;

    uint256 assets = redeem(e, shares, receiver, owner);
    mathint lhs1 = _receiverAssets + assets;
    mathint rhs1 = asset.totalSupply();
    require lhs1 <= rhs1;

    uint256 totalAssets_ = asset.balanceOf(currentContract);
    uint256 receiverAssets_ = asset.balanceOf(receiver);
    uint256 ownerShares_ = balanceOf(owner);
    uint256 senderAllowance_ = allowance(owner, e.msg.sender);

    mathint lhs2 = _totalAssets - assets;
    mathint rhs2 = totalAssets_;
    assert lhs2 == rhs2;
    mathint lhs3 = _receiverAssets + assets;
    mathint rhs3 = receiverAssets_;
    assert lhs3 == rhs3;
    mathint lhs4 = _ownerShares - shares;
    mathint rhs4 = ownerShares_;
    assert lhs4 == rhs4;
    mathint lhs5 = _senderAllowance - shares;
    mathint rhs5 = senderAllowance_;
    assert e.msg.sender != owner => 
        _senderAllowance == 2^256 -1 && senderAllowance_ == 2^256 -1 
        || lhs5 == rhs5;
}*/

// Float Balance Above Minimum After Rebalance**
/* This rule ensures that after calling the `rebalance` function, the USDC balance (`usdcBalance()`) is greater
   than or equal to the minimum required float balance (`totalAssets() * floatPercentage`). If the condition is
   not met, the rule expects the `FloatBalanceTooLow` error. */
/*rule floatBalanceAboveMinimumAfterRebalance(bytes[] _callData) { // fails on delegateCall (IAdapter dependency)
    env e;
    require totalAssets() > 0;
    rebalance(e, _callData);
    //uint256 floatRequired = totalAssets().mulWadDown(floatPercentage());
    mathint floatRequired = totalAssets() * floatPercentage();
    mathint usdcBal = usdcBalance();
    assert usdcBal >= floatRequired, "FloatBalanceTooLow";
}*/

// End USDC Balance Above Minimum After Exit**
/* This rule checks that after calling the `exitAllPositions` function with a specified minimum USDC balance
(`minBalance`), the USDC balance after the function call (`usdcBalance()`) is greater than or equal to the
specified minimum balance. If the condition is not met, the rule expects the `EndUsdcBalanceTooLow` error. */
/*rule endUsdcBalanceAboveMinimumAfterExit(uint256 minBalance) {
    env e;
    require totalAssets() > 0;
    exitAllPositions(e, minBalance);
    assert usdcBalance() >= minBalance, "EndUsdcBalanceTooLow";
}*/

// Total Debt Repaid After Exit**
/* This rule checks that after calling the `exitAllPositions` function, the total debt (`totalDebt()`) is zero,
   ensuring that all debt has been repaid. The rule requires the initial total debt to be greater than zero. */
/*rule totalDebtRepaidAfterExit() {
    env e;
    require totalDebt(e) > 0;
    exitAllPositions(e, 0);
    assert totalDebt(e) == 0, "Total debt not repaid";
}*/

// **Total Collateral Withdrawn After Exit**
/* This rule checks that after calling the `exitAllPositions` function, the total collateral (`totalCollateral()`)
   is zero, ensuring that all collateral has been withdrawn. The rule requires the initial total collateral to be
   greater than zero. */
/*rule totalCollateralWithdrawnAfterExit() {
    env e;
    require totalCollateral(e) > 0;
    exitAllPositions(e, 0);
    assert totalCollateral(e) == 0, "Total collateral not withdrawn";
}*/

// **Investment After Rebalance**
/* This rule checks that after calling the `rebalance` function, any WETH balance remaining after rebalancing is
   invested in the `scWETH` contract. The rule compares the initial and final values of `wethInvested()` and
   `_wethBalance()` to ensure that the appropriate amount of WETH is invested.
*/
/*rule investmentAfterRebalance(bytes[] _callData) { // fails on delegateCall (IAdapter dependency)
    env e;
    uint256 initialInvested = wethInvested();
    uint256 initialWethBalance = weth.balanceOf(currentContract);
    rebalance(e, _callData);
    uint256 newInvested = wethInvested();
    uint256 newWethBalance = weth.balanceOf(currentContract);
    mathint lhs = newInvested;
    mathint rhs = initialInvested + initialWethBalance - newWethBalance;
    assert lhs >= rhs, "WETH not invested after rebalance";
}*/

// **Correct Profit Calculation**
/* This rule verifies that the `getProfit` function correctly calculates the profit based on the difference
   between the invested WETH (`wethInvested()`) and the total debt (`totalDebt()`). */
/*rule correctProfitCalculation() {
    env e;
    uint256 invested = wethInvested();
    uint256 debt = totalDebt();
    mathint expectedProfit = invested > debt ? invested - debt : 0;
    mathint getP = getProfit();
    assert getP == expectedProfit, "Incorrect profit calculation";
}*/

// **Disinvestment After Sell Profit**
/* This rule checks that after calling the `sellProfit` function, a portion of the invested WETH
   (`wethInvested()`) is disinvested, and the USDC balance (`usdcBalance()`) is increased. The rule requires
   that there is initially some profit (`getProfit() > 0`), and it verifies that the invested WETH decreases
   and the USDC balance increases after the function call. */
rule disinvestmentAfterSellProfit(uint256 usdcAmountOutMin) {
    env e;
    require getProfit() > 0;
    uint256 initialInvested = wethInvested();
    uint256 initialUsdcBalance = usdcBalance();
    sellProfit(e, usdcAmountOutMin);
    uint256 newInvested = wethInvested();
    uint256 newUsdcBalance = usdcBalance();
    assert newInvested < initialInvested, "WETH not disinvested after sell profit";
    assert newUsdcBalance > initialUsdcBalance, "USDC balance not increased after sell profit";
}
