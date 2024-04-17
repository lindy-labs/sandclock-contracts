import "erc20.spec";

using MockUSDC as asset;
using WETH as weth;
using scWETH as wethVault;
using AaveV3ScUsdcAdapter as adapter;
using MockWstETH as wstETH;
using PriceConverter as priceConverter;

methods {
    // state mofidying functions
    function supplyNew(uint256 _adapterId, uint256 _amount) external;
    function borrowNew(uint256 _adapterId, uint256 _amount) external;
    function mint(uint256 shares, address receiver) external returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256);
    function rebalanceWithoutOperations() external;
    function exitAllPositions(uint256) external;
    //function totalCollateral() external;
    function sellProfit(uint256 _usdcAmountOutMin) external ;
    function setSwapperByAddress(address _newSwapper) external;
    function currentContract.whiteListOutTokenByAddress(address _token, bool _value) external;
    function currentContract.addAdapterByAddress(address _adapter) external;
    function removeAdapter(uint256 _adapterId, bool _force) external;
    function disinvest(uint256 _amount) external;

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
    function totalCollateral() external returns (uint256) envfree;
    function currentContract.getSwapper() external returns (address) envfree;
    function currentContract.isTokenWhitelistedByAddress(address _token) external returns (bool) envfree;
    function isSupported(uint256 _adapterId) external returns (bool) envfree;
    function getAdapter(uint256 _adapterId) external returns (address) envfree;
    function currentContract.getAdapterId(address _adapter) external returns (uint256) envfree;
    function getPALength() external returns (uint256) envfree;
    function currentContract.getCollateral(uint256 _adapterId) external returns (uint256) envfree;
    function currentContract.getDebt(uint256 _adapterId) external returns (uint256) envfree;
    function priceConverter.ethToUsdc(uint256 _ethAmount) external returns (uint256) envfree;
    
    // erc20
    function asset.totalSupply() external returns (uint256) envfree;
    function asset.balanceOf(address) external returns (uint256) envfree;
    function weth.balanceOf(address) external returns (uint256) envfree;
    function wstETH.getWstETHByStETH(uint256 _stETHAmount) external returns (uint256) envfree;

    // state constants
    function _.getCollateral(address _adapter) external                 => DISPATCHER(true);
    function _.getDebt(address _adapter) external                       => DISPATCHER(true);
    function _.withdraw(address _adapter) external                      => DISPATCHER(true);
    function _.id() external                                            => DISPATCHER(true);
    function _.setApprovals() external                                  => DISPATCHER(true);
    function _.revokeApprovals() external                               => DISPATCHER(true);
    function _.supply(uint256 _amount) external     => DISPATCHER(true);
    function _.borrow(uint256 _amount) external     => DISPATCHER(true);
}

definition delta(mathint a, mathint b) returns mathint = a > b ? a - b : b - a;

definition percentDelta(uint256 a, uint256 b) returns mathint = (delta(a, b) * (10 ^ 18)) / b;

definition assertApproxEqRel(uint256 a, uint256 b, uint256 maxD) returns bool = (b == 0 ? (a == b):percentDelta(a, b)<=to_mathint(maxD));

/*
    @Rule

    @Category: High

    @Description:
        the function call rebalance(operations) rebalances the vault's positions/loans in multiple lending markets
*/
rule integrity_of_rebalance(address _adapter, uint256 initialBalance, uint256 initialDebt) {
    env e;
    require _adapter == adapter;
    require getPALength() == 0;
    addAdapterByAddress(e, _adapter);
    uint256 adapterId = getAdapterId(_adapter);
    assert getAdapter(adapterId) == _adapter;

    require asset.balanceOf(currentContract) == initialBalance;
    require weth.balanceOf(currentContract) > 0; // Force investing

    supplyNew(e, adapterId, initialBalance);
    borrowNew(e, adapterId, initialDebt);

    rebalanceWithoutOperations(e);

    mathint collateral_ = getCollateral(adapterId);
    mathint debt_ = getDebt(adapterId);

    assert delta(collateral_, to_mathint(initialBalance)) <= 1;
    assert delta(debt_, to_mathint(initialDebt)) <= 1;
}
/*
    @Rule

    @Category: High

    @Description:
        the function call sellProfit(_usdcAmountOutMin) sells WETH profits (swaps to USDC), as long as the weth invested is greater than the total debt
*/
/*rule integrity_of_sellProfit(address _adapter, uint256 initialBalance, uint256 _usdcAmountOutMin) { // Timed out
    env e;
    require _adapter == adapter;
    require getPALength() == 0;
    addAdapterByAddress(e, _adapter);
    uint256 adapterId = getAdapterId(_adapter);
    assert getAdapter(adapterId) == _adapter;

    require asset.balanceOf(currentContract) == initialBalance;
    uint256 _getDebt = getDebt(adapterId);
    uint256 _totalDebt = totalDebt();
    uint256 _wethInvested = wethInvested();
    uint256 _getProfit = getProfit();
    mathint _usdcBalance = usdcBalance();

    require _wethInvested > _totalDebt; // Avoid sellProfit to revert

    sellProfit(e, _usdcAmountOutMin);

    assert _getDebt == getDebt(adapterId);
    assert _totalDebt == totalDebt();
    assert getProfit() == 0;

}*/
/*
    @Rule

    @Category: Unit test

    @Description:
        function sellProfit reverts if the weth invested is less than or equal to the total debt
*/
/*rule sellProfit_reverts_if_wethInvested_is_less_than_or_equal_to_totalDebt(address _adapter, uint256 initialBalance, uint256 _usdcAmountOutMin) {
    env e;
    require _adapter == adapter;
    require getPALength() == 0;
    addAdapterByAddress(e, _adapter);
    uint256 adapterId = getAdapterId(_adapter);
    assert getAdapter(adapterId) == _adapter;

    require asset.balanceOf(currentContract) == initialBalance;
    require wethInvested() <= totalDebt(); // Expected to revert

    sellProfit@withrevert(e, _usdcAmountOutMin);
    assert lastReverted;
}*/

/*
    @Rule

    @Category: Medium

    @Description:
        the function call supply(balance) supplies USDC assets (balance) to a lending market
*/
/*rule integrity_of_supply(address _adapter, uint256 initialBalance) { // Not OK
    env e;
    require _adapter == adapter;
    require getPALength() == 0;
    addAdapterByAddress(e, _adapter);
    uint256 adapterId = getAdapterId(_adapter);
    assert getAdapter(adapterId) == _adapter;

    require asset.balanceOf(currentContract) == initialBalance;

    adapter.supply(e, initialBalance);

    assert adapter.getCollateral(e, currentContract) == initialBalance;

}*/
/*
    @Rule

    @Category: Medium

    @Description:
        the function call borrow(balance) borrows WETH from a lending market
*/
/*rule integrity_of_borrow(address _adapter, uint256 initialBalance, uint256 borrowAmount) { // Not OK
    env e;
    require _adapter == adapter;
    require getPALength() == 0;
    addAdapterByAddress(e, _adapter);
    uint256 adapterId = getAdapterId(_adapter);
    assert getAdapter(adapterId) == _adapter;

    require asset.balanceOf(currentContract) == initialBalance;

    adapter.supply(e, initialBalance);

    adapter.borrow(e, borrowAmount);

    assert adapter.getDebt(e, currentContract) == borrowAmount;

}*/
/*
    @Rule

    @Category: Medium

    @Description:
        the function call repay(amount) repays WETH to a lending market
*/
/*
rule integrity_of_repay(address _adapter) { // Not OK
    env e;
    require _adapter == adapter;
    require getPALength() == 0;
    addAdapterByAddress(e, _adapter);
    uint256 adapterId = getAdapterId(_adapter);
    assert getAdapter(adapterId) == _adapter;

    uint256 initialBalance = 10 ^ 10;
    uint256 borrowAmount = 2 * 10 ^ 18;

    require asset.balanceOf(currentContract) == initialBalance;

    adapter.supply(e, initialBalance);
    adapter.borrow(e, borrowAmount);

    uint256 repayAmount = 10 ^ 18;
    adapter.repay(e, repayAmount);

    assert delta(adapter.getDebt(e, currentContract), borrowAmount - repayAmount) <= 1;
}
*/
/*
    @Rule

    @Category: Medium

    @Description:
        the function call withdraw(amount) withdraws USDC assets from a lending market
*/
/*rule integrity_of_withdraw(address _adapter) { // Not OK
    env e;
    require _adapter == adapter;
    require getPALength() == 0;
    addAdapterByAddress(e, _adapter);
    uint256 adapterId = getAdapterId(_adapter);
    assert getAdapter(adapterId) == _adapter;

    uint256 initialBalance = 10 ^ 10;
    require asset.balanceOf(currentContract) == initialBalance;
    
    adapter.supply(e, initialBalance);
    adapter.borrow(e, 10 ^ 18);

    uint256 withdrawAmount = 5 * 10 ^ 9;
    adapter.withdraw(e, withdrawAmount);

    //assert usdcBalance() == withdrawAmount; // Not OK
    assert delta(adapter.getCollateral(e, currentContract), initialBalance - withdrawAmount) <= 1; // Not OK
}*/
/*
    @Rule

    @Category: Medium

    @Description:
        the function call disinvest(amount) withdraws WETH from the staking vault (scWETH)
*/
/*rule integrity_of_disinvest(address _adapter) { // Not OK (Timed-out)
    env e;
    require _adapter == adapter;
    require getPALength() == 0;
    addAdapterByAddress(e, _adapter);
    uint256 adapterId = getAdapterId(_adapter);
    assert getAdapter(adapterId) == _adapter;

    uint256 initialBalance = 10 ^ 12;
    uint256 initialDebt = 100 * 10 ^ 18;

    require asset.balanceOf(currentContract) == initialBalance;

    adapter.supply(e, initialBalance);
    adapter.borrow(e, initialDebt);

    rebalanceWithoutOperations(e);

    uint256 disinvestAmount = assert_uint256(wethInvested() / 2);

    disinvest(e, disinvestAmount);

    assert weth.balanceOf(currentContract) == disinvestAmount;
    assert to_mathint(wethInvested()) == initialDebt - disinvestAmount; // Not OK
}*/
/*
    @Rule

    @Category: Medium

    @Description:
        the function call exitAllPositions(minBalance) makes usdc balance at least equals to minBalance
*/
/*rule endUsdcBalanceAboveMinimumAfterExit(uint256 minBalance) {
    env e;
    require totalAssets() > 0;
    exitAllPositions(e, minBalance);
    assert usdcBalance() >= minBalance, "EndUsdcBalanceTooLow";
}*/

/*
    @Rule

    @Category: Medium

    @Description:
        the function call exitAllPositions(0) makes total debt to be 0
*/
/*rule totalDebtRepaidAfterExit() {
    env e;
    require totalDebt(e) > 0;
    exitAllPositions(e, 0);
    assert totalDebt(e) == 0, "Total debt not repaid";
}*/

/*
    @Rule

    @Category: Medium

    @Description:
        the function call exitAllPositions(0) makes total collateral to be 0
*/
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
/*rule integrity_of_addAdapter(address _adapter) {
    env e;
    require _adapter == adapter;
    uint256 adapterId = getAdapterId(_adapter);
    require !isSupported(adapterId);
    addAdapterByAddress(e, _adapter);
    assert getAdapter(adapterId) == _adapter;
}*/

/*
    @Rule

    @Category: Unit test

    @Description:
        function addAdapter reverts if _adapter is already present in protocolAdapters
*/
/*rule addAdapter_reverts_if_address_is_already_present(address _adapter) {
    env e;
    require _adapter == adapter;
    uint256 adapterId = getAdapterId(_adapter);
    require isSupported(adapterId);
    addAdapterByAddress@withrevert(e, _adapter);
    assert lastReverted;
}*/

/*
    @Rule

    @Category: Medium

    @Description:
        function removeAdapter updates the state variable protocolAdapters with the value provided by the parameter _adapterId
*/
/*rule integrity_of_removeAdapter(uint256 _adapterId) {
    env e;
    require getAdapter(_adapterId) == adapter;
    require(adapter.getCollateral(e, currentContract) == 0);
    removeAdapter(e, _adapterId, true);
    assert !isSupported(_adapterId);
}*/

/*
    @Rule

    @Category: Unit test

    @Description:
        function removeAdapter reverts if _adapterId cannot be removed from protocolAdapters (it is being used)
*/
/*rule removeAdapter_reverts_if_adapter_is_being_used(uint256 _adapterId, bool _forced) {
    env e;
    require getAdapter(_adapterId) == adapter;
    require(!_forced && adapter.getCollateral(e, currentContract) > 0);
    removeAdapter@withrevert(e, _adapterId, _forced);
    assert lastReverted;
}*/

/*
    @Rule

    @Category: High

    @Description:
        function addAdapter followed by removeAdapter do not change protocolAdapters for the same adapter
*/
/*rule addAdapter_followed_by_removeAdapter(address _adapter) {
    env e;
    require _adapter == adapter;
    uint256 _adapterId = getAdapterId(_adapter);
    require !isSupported(_adapterId);
    addAdapterByAddress(e, _adapter);
    assert getAdapter(_adapterId) == _adapter;
    removeAdapter(e, _adapterId, true);
    assert !isSupported(_adapterId);
}*/

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

