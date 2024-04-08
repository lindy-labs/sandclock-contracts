import "erc20.spec";

using USDC as asset;
using WETH as weth;
using AaveV2ScUsdcAdapter as adapter;
using MockWstETH as wstETH;

methods {
    // state mofidying functions
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
    
    // erc20
    function asset.totalSupply() external returns (uint256) envfree;
    function asset.balanceOf(address) external returns (uint256) envfree;
    function weth.balanceOf(address) external returns (uint256) envfree;
    function wstETH.getWstETHByStETH(uint256 _stETHAmount) external returns (uint256) envfree;


    // state constants
    function _.getCollateral(address _adapter) external     => DISPATCHER(true);
    function _.getDebt(address _adapter) external           => DISPATCHER(true);
    function _.id() external                                => DISPATCHER(true);
    function _.setApprovals() external                      => DISPATCHER(true);
    function _.revokeApprovals() external                   => DISPATCHER(true);
    function _.supply(uint256 _amount) external             => DISPATCHER(true);
    function _.borrow(uint256 _amount) external             => DISPATCHER(true);
}

definition delta(uint256 a, uint256 b) returns mathint = a > b ? a - b : b - a;

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

    adapter.supply(e, initialBalance);
    adapter.borrow(e, initialDebt);

    rebalanceWithoutOperations(e);

    assert totalCollateral() == initialBalance;

    uint256 collateral = getCollateral(adapterId);

    assert delta(collateral, initialBalance) <= 1;
}

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

