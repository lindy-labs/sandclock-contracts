import "erc20.spec";

using USDC as asset;
using WETH as weth;
using AaveV2ScUsdcAdapter as adapter;

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
    function setSwapperByAddress(address _newSwapper) external;
    function currentContract.whiteListOutTokenByAddress(address _token, bool _value) external;
    function addAdapterByAddress(address _adapter) external;

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
    function currentContract.getSwapper() external returns (address) envfree;
    function currentContract.isTokenWhitelistedByAddress(address _token) external returns (bool) envfree;
    function isSupported(uint256 _adapterId) external returns (bool) envfree;
    function getAdapter(uint256 _adapterId) external returns (address) envfree;
    function getAdapterId(address _adapter) external returns (uint256) envfree;
    
    // erc20
    function asset.totalSupply() external returns (uint256) envfree;
    function asset.balanceOf(address) external returns (uint256) envfree;
    function weth.balanceOf(address) external returns (uint256) envfree;


    // state constants
    function _.getCollateral(address _account) external     => DISPATCHER(true);
    function _.getDebt(address _account) external           => DISPATCHER(true);
    function _.id() external                                => DISPATCHER(true);
    function adapter.setApprovals() external;
}

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

/*
    @Rule

    @Category: Medium

    @Description:
        function addAdapter updates the state variable protocolAdapters with the value provided by the parameter _adapter
*/
rule integrity_of_addAdapter(address _adapter) { // Not OK (Dependency)
    env e;
    require _adapter == adapter;
    uint256 adapterId = getAdapterId(_adapter);
    require !isSupported(adapterId);
    addAdapterByAddress(e, _adapter);
    assert getAdapter(adapterId) == _adapter;
}

/*
    @Rule

    @Category: Unit test

    @Description:
        function addAdapter reverts if _adapter is already present in protocolAdapters
*/
rule addAdapter_reverts_if_address_is_already_present(address _adapter) { // Not OK (Dependency)
    env e;
    require _adapter == adapter;
    uint256 adapterId = getAdapterId(_adapter);
    require isSupported(adapterId);
    addAdapterByAddress@withrevert(e, _adapter);
    assert lastReverted;
}

/*
    @Rule

    @Category: Medium

    @Description:
        function whiteListOutToken updates the state variable zeroExSwapWhitelist with the value provided by the parameters _token and _value
*/
/*rule integrity_of_whiteListOutToken(address _token, bool _value) {
    env e;
    require _token != 0;
    whiteListOutTokenByAddress(e, _token, _value);
    assert isTokenWhitelistedByAddress(_token) == _value;
}*/

/*
    @Rule

    @Category: Unit test

    @Description:
        function whiteListOutToken reverts if address(0)
*/
/*rule whiteListOutToken_reverts_if_address_is_zero(bool _value) {
    env e;
    whiteListOutTokenByAddress@withrevert(e, 0, _value);
    assert lastReverted;
}*/

/*
    @Rule

    @Category: Medium

    @Description:
        function setSwapper updates the state variable swapper with the value provided by the parameter _newSwapper
*/
/*rule integrity_of_setSwapper(address _newSwapper) {
    env e;
    require _newSwapper != 0;
    setSwapperByAddress(e, _newSwapper);
    assert currentContract.getSwapper() == _newSwapper;
}*/

/*
    @Rule

    @Category: Unit test

    @Description:
        function setSwapper reverts if address(0)
*/
/*rule setSwapper_reverts_if_address_is_zero() {
    env e;
    setSwapperByAddress@withrevert(e, 0);
    assert lastReverted;
}*/

