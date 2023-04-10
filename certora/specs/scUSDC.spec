import "erc20.spec"

using USDC as asset

methods {
    // state modifying functions
    harvest()
    changeLeverage(uint256 _targetLtv)
    depositIntoStrategy()
    withdrawToVault(uint256 amount)
    receiveFlashLoan(address[] null, uint256[] amounts, uint256[] null, bytes userData)
    setPerformanceFee(uint256 newPerformanceFee)
    setFloatPercentage(uint256 newFloatPercentage)
    setTreasury(address newTreasury)
    depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
    deposit(uint256 assets, address receiver) returns (uint256)
    mint(uint256 shares, address receiver) returns (uint256)
    withdraw(uint256 assets, address receiver, address owner) returns (uint256)
    redeem(uint256 shares, address receiver, address owner) returns (uint256)
    permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
    grantRole(bytes32 role, address account)
    revokeRole(bytes32 role, address account)
    renounceRole(bytes32 role, address account)
    setSlippageTolerance(uint256 _newSlippageTolerance)
    applyNewTargetLtv(uint256 _newTargetLtv)
    currentContract.rebalance()
    currentContract.exitAllPositions()

    // view functions
    convertToShares(uint256 assets) returns (uint256) // omit envfree for some rules
    convertToAssets(uint256 shares) returns (uint256) // omit envfree for some rules
    totalAssets() returns (uint256) envfree
    totalCollateralSupplied() returns (uint256) envfree
    totalDebt() returns (uint256) envfree
    getLeverage() returns (uint256) envfree
    getLtv() returns (uint256) envfree
    previewDeposit(uint256 assets) returns (uint256) envfree
    previewMint(uint256 shares) returns (uint256) envfree
    previewWithdraw(uint256 assets) returns (uint256) envfree
    previewRedeem(uint256 shares) returns (uint256) envfree
    maxDeposit(address null) returns (uint256) envfree
    maxMint(address null) returns (uint256) envfree
    maxWithdraw(address owner) returns (uint256) envfree
    maxRedeem(address owner) returns (uint256) envfree
    DOMAIN_SEPARATOR() returns (bytes32) envfree
    supportsInterface(bytes4 interfaceId) returns (bool) envfree
    hasRole(bytes32 role, address account) returns (bool) envfree
    getRoleAdmin(bytes32 role) returns (bytes32) envfree
    getCollateral() returns (uint256) envfree
    getDebt() returns (uint256) envfree
    getInvested() returns (uint256) envfree
    getUsdcBalance() returns (uint256) envfree

    // state variables
    totalInvested() returns (uint256) envfree
    totalProfit() returns (uint256) envfree
    targetLtv() returns (uint256) envfree
    slippageTolerance() returns (uint256) envfree
    performanceFee() returns (uint256) envfree
    floatPercentage() returns (uint256) envfree
    treasury() returns (address) envfree
    nonces(address) returns (uint256) envfree

   // state constants
    curvePool() returns (address) envfree
    stEth() returns (address) envfree
    wstETH() returns (address) envfree
    weth() returns (address) envfree
    stEThToEthPriceFeed() returns (address) envfree
    balancerVault() returns (address) envfree
    getMaxLtv() returns (uint256) envfree
    KEEPER_ROLE() returns (bytes32) envfree
    asset() returns (address) envfree
    DEFAULT_ADMIN_ROLE() returns (bytes32) envfree

    // erc20
    currentContract.totalSupply() returns (uint256) envfree
    currentContract.balanceOf(address) returns (uint256) envfree
    currentContract.allowance(address, address) returns (uint256) envfree
    asset.totalSupply() returns (uint256) envfree
    asset.balanceOf(address) returns (uint256) envfree
}

definition ONE() returns uint256 = 10^18;

definition coreFunctions(method f) returns bool =
    f.selector == mint(uint256, address).selector
    ||
    f.selector == depositWithPermit(uint256, uint256, uint8, bytes32, bytes32).selector
    ||
    f.selector == deposit(uint256, address).selector
    ||
    f.selector == withdraw(uint256, address, address).selector
    ||
    f.selector == redeem(uint256, address, address).selector;

ghost uint256 totalShares {
    init_state axiom totalShares == 0;
}
hook Sstore balanceOf[KEY address k] uint256 amount (uint256 oldAmount) STORAGE {
    totalShares = totalShares + amount - oldAmount;
}
/*
    @Invariant

    @Category: High level

    @Description:
        totalSupply == sum(balanceOf(user))
*/
invariant totalSupply_equals_totalShares()
    totalSupply() == totalShares
    filtered { f->!f.isView }

/*
    @Rule

    @Category: High level

    @Description:
        function converToShares returns the same value for a given parameter regardless of the caller
*/
rule converToShares_returns_the_same_value(uint256 assets) {
    env e;
    uint256 _shares = convertToShares(e, assets);
    env e2;
    require e2.msg.sender != e.msg.sender;
    uint256 shares_ = convertToShares(e2, assets);
    assert _shares == shares_;
}

/*
    @Rule

    @Category: High level

    @Description:
        function convertToShares returns at least the same amount of shares than function previewDeposit
*/
rule convertToShares_gte_previewDeposit(uint256 assets) {
    env e;
    assert convertToShares(e, assets) >= previewDeposit(assets);
}

/*
    @Rule

    @Category: High level

    @Description:
        function converToShares rounds down shares towards zero
*/
rule converToShares_rounds_down_towards_0(uint256 assets) {
    env e;
    require totalSupply() != 0;
    assert (assets * totalSupply()) / totalAssets() == convertToShares(e, assets);
}

/*
    @Rule

    @Category: High level

    @Description:
        function convertToShares maintains share prices
*/
rule share_price_maintained_after_non_core_functions(uint256 assets, method f) filtered {
    f -> !f.isView && !coreFunctions(f) &&
    f.selector != harvest().selector
} {
    requireInvariant totalSupply_equals_totalShares;
    env e;
    uint256 _shares = convertToShares(e, assets);

    env e1;
    require e1.msg.value == 0;
    calldataarg args;
    f(e1, args);

    env e2;

    uint256 shares_ = convertToShares(e2, assets);

    assert _shares == shares_;
}

/*
    @Rule

    @Category: High level

    @Description:
        share price maintained after mint
*/
rule share_price_maintained_after_mint(uint256 shares, address receiver) {
    env e;
    require e.msg.sender != currentContract;
    require receiver != currentContract;
    require e.msg.sender != receiver;

    uint256 _totalAssets = totalAssets();
    require _totalAssets == 0 <=> totalSupply() == 0;

    uint256 assets = mint(e, shares, receiver);
    require _totalAssets + assets <= asset.totalSupply(); // avoid overflow
    
    assert assets == previewMint(shares);
}


/*
    @Rule

    @Category: High level

    @Description:
        function convertToAssets returns the same value for a given parameter regardless of the caller
*/
rule convertToAssets_returns_the_same_value(uint256 shares) {
    env e;
    uint256 _assets = convertToAssets(e, shares);
    env e2;
    require e2.msg.sender != e.msg.sender;
    uint256 assets_ = convertToAssets(e2, shares);
    assert _assets == assets_;
}

/*
    @Rule

    @Category: High level

    @Description:
        function convertToAssets returns at most the same amount of assets than function previewMint
*/
rule convertToAssets_lte_previewMint(uint256 shares) {
    env e;
    assert convertToAssets(e, shares) <= previewMint(shares);
}

/*
    @Rule

    @Category: High level

    @Description:
        function convertToAssets rounds assets towards zero
*/
rule convertToAssets_rounds_down_towards_0(uint256 shares) {
    env e;
    require totalSupply() != 0;
    assert (shares * totalAssets()) / totalSupply() == convertToAssets(e, shares);
}

/*
    @Rule

    @Category: High level

    @Description:
        function maxDeposit returns the maximum expected value of a deposit
*/
rule maxDeposit_returns_correct_value(address receiver) {
    assert maxDeposit(receiver) == 2^256 - 1;
}

/*
    @Rule

    @Category: High level

    @Description:
        function maxMint returns the maximum expected value of a mint
*/
rule maxMint_returns_correct_value(address receiver) {
    assert maxMint(receiver) == 2^256 - 1;
}

/*
    @Rule

    @Category: High level

    @Description:
        function previewDeposit returns at most the same amount of assets than function deposit
*/
rule previewDeposit_lte_deposit(uint256 assets, address receiver) {
    env e;
    assert previewDeposit(assets) <= deposit(e, assets, receiver);
}

/*
    @Rule

    @Category: High level

    @Description:
        function previewMint returns at least the same amount of shares than function mint
*/
rule previewMint_gte_mint(uint256 shares, address receiver) {
    env e;
    assert previewMint(shares) >= mint(e, shares, receiver);
}

/*
    @Rule

    @Category: High level

    @Description:
        function previewWithdraw returns at least the same amount of assets than function withdraw
*/
rule previewWithdraw_gte_withdraw(uint256 assets, address receiver, address owner) {
    env e;
    assert previewWithdraw(assets) >= withdraw(e, assets, receiver, owner);
}

/*
    @Rule

    @Category: High level

    @Description:
        function previewRedeem returns at most the same amount of shares than function redeem
*/
rule previewRedeem_lte_redeem(uint256 shares, address receiver, address owner) {
    env e;
    assert previewRedeem(shares) <= redeem(e, shares, receiver, owner);
}

// TODO depositWithPermit

/*
    @Rule

    @Category: High level

    @Description:
        function deposit mints exactly shares Vault shares to receiver by depositing exactly assets of underlying tokens
*/
rule integrity_of_deposit(uint256 assets, address receiver) {
    env e;
    require e.msg.sender != currentContract;
    require receiver != currentContract;
    
    uint256 _userAssets = asset.balanceOf(e.msg.sender);
    uint256 _totalAssets = asset.balanceOf(currentContract);
    require _totalAssets + assets <= asset.totalSupply();
    uint256 _receiverShares = balanceOf(receiver);

    uint256 shares = deposit(e, assets, receiver);

    require _receiverShares + shares <= totalSupply();

    uint256 userAssets_ = asset.balanceOf(e.msg.sender);
    uint256 totalAssets_ = asset.balanceOf(currentContract);
    uint256 receiverShares_ = balanceOf(receiver);

    assert _userAssets - assets == userAssets_;
    assert _receiverShares + shares == receiverShares_;
    assert _totalAssets + assets == totalAssets_;
}

/*
    @Rule

    @Category: Unit test

    @Description:
        function deposit must revert if all of assets cannot be deposited
*/
rule deposit_reverts_if_not_enough_assets(uint256 assets, address receiver) {
    env e;
    uint256 userAssets = asset.balanceOf(e.msg.sender);
    require userAssets < assets;
    deposit@withrevert(e, assets, receiver);
    assert lastReverted;
}

/*
    @Rule

    @Category: High

    @Description:
        function mint mints exactly shares Vault shares to receiver
*/
rule integrity_of_mint(uint256 shares, address receiver) {
    env e;
    require e.msg.sender != currentContract;
    require receiver != currentContract;

    uint256 _userAssets = asset.balanceOf(e.msg.sender);
    uint256 _totalAssets = asset.balanceOf(currentContract);
    uint256 _receiverShares = balanceOf(receiver);
    require _receiverShares + shares <= totalSupply();

    uint256 assets = mint(e, shares, receiver);
    require _totalAssets + assets <= asset.totalSupply();

    uint256 userAssets_ = asset.balanceOf(e.msg.sender);
    uint256 totalAssets_ = asset.balanceOf(currentContract);
    uint256 receiverShares_ = balanceOf(receiver);

    assert _userAssets - assets == userAssets_;
    assert _totalAssets + assets == totalAssets_;
    assert _receiverShares + shares == receiverShares_;
}

/*
    @Rule

    @Category: Unit test

    @Description:
        function mint must revert if the minter has not enough assets
*/
rule mint_reverts_if_not_enough_assets(uint256 shares, address receiver) {
    env e;
    uint256 assets = previewMint(shares);

    require asset.balanceOf(e.msg.sender) < assets;

    mint@withrevert(e, shares, receiver);

    assert lastReverted;
}

/*
    @Rule

    @Category: High

    @Description:
        function withdraw must burn shares from owner and sends exactly assets of underlying tokens to receiver
*/
rule integrity_of_withdraw(uint256 assets, address receiver, address owner) {
    env e;
    require e.msg.sender != currentContract;
    require receiver != currentContract;
    require e.msg.sender != owner;
    require owner != currentContract;
    require owner != receiver;

    uint256 _receiverAssets = asset.balanceOf(receiver);
    require _receiverAssets + assets <= asset.totalSupply();
    uint256 _ownerShares = balanceOf(owner);
    uint256 _senderAllowance = allowance(owner, e.msg.sender);

    uint256 shares = withdraw(e, assets, receiver, owner);

    uint256 receiverAssets_ = asset.balanceOf(receiver);
    uint256 ownerShares_ = balanceOf(owner);
    uint256 senderAllowance_ = allowance(owner, e.msg.sender);

    assert _receiverAssets + assets == receiverAssets_;
    assert _ownerShares - shares == ownerShares_;
    assert e.msg.sender != owner => 
        _senderAllowance == 2^256 -1 && senderAllowance_ == 2^256 -1 
        || _senderAllowance - shares == senderAllowance_;
}

/*
    @Rule

    @Category: Unit test

    @Description:
        function withdraw reverts if there is not enough assets
*/
rule withdraw_reverts_if_not_enough_assets(uint256 assets, address receiver, address owner) {
    require asset.balanceOf(currentContract) < assets;

    env e;
    withdraw@withrevert(e, assets, receiver, owner);

    assert lastReverted;
}

/*
    @Rule

    @Category: High

    @Description:
        function redeem must burn exactly shares from owner and sends assets of underlying tokens to receiver
*/
rule integrity_of_redeem(uint256 shares, address receiver, address owner) {
    env e;
    uint256 _receiverAssets = asset.balanceOf(receiver);
    uint256 _totalAssets = asset.balanceOf(currentContract);
    uint256 _ownerShares = balanceOf(owner);
    uint256 _senderAllowance = allowance(owner, e.msg.sender);

    require e.msg.sender != currentContract;
    require receiver != currentContract;

    uint256 assets = redeem(e, shares, receiver, owner);
    require _receiverAssets + assets <= asset.totalSupply();

    uint256 totalAssets_ = asset.balanceOf(currentContract);
    uint256 receiverAssets_ = asset.balanceOf(receiver);
    uint256 ownerShares_ = balanceOf(owner);
    uint256 senderAllowance_ = allowance(owner, e.msg.sender);

    assert _totalAssets - assets == totalAssets_;
    assert _receiverAssets + assets == receiverAssets_;
    assert _ownerShares - shares == ownerShares_;
    assert e.msg.sender != owner => 
        _senderAllowance == 2^256 -1 && senderAllowance_ == 2^256 -1 
        || _senderAllowance - shares == senderAllowance_;
}

/*
    @Rule

    @Category: Unit test

    @Description:
        function redeem reverts if there is not enough shares
*/
rule redeem_reverts_if_not_enough_shares(uint256 shares, address receiver, address owner) {
    env e;
    require balanceOf(owner) < shares || e.msg.sender != owner && allowance(owner, e.msg.sender) < shares;
    redeem@withrevert(e, shares, receiver, owner);
    assert lastReverted;
}

/*
    @Rule

    @Category: Unit test

    @Description:
        function changeLeverage updates the state variable flashloanLtv using newFlashloanLtv
*/
rule integrity_of_changeLeverage(uint256 newFlashloanLtv) {
    env e;
    changeLeverage(e, newFlashloanLtv);
    assert targetLtv() == newFlashloanLtv;
}

/*
    @Rule

    @Category: Unit test

    @Description:
        function changeLeverage reverts if newFlashloanLtv exceeds maxLtv
*/
rule changeLeverage_reverts_if_newFlashloanLtv_too_high(uint256 newFlashloanLtv) {
    env e;
    require newFlashloanLtv > getMaxLtv();
    changeLeverage@withrevert(e, newFlashloanLtv);
    assert lastReverted;
}

/*
    @Rule

    @Category: Unit test

    @Description:
        function receiveFlashloan reverts if the caller is not the balancerVault
*/
rule receiveFlashLoan_reverts_if_caller_invalid() {
    env e;
    require e.msg.sender != balancerVault();
    calldataarg args;
    receiveFlashLoan@withrevert(e, args);
    assert lastReverted;
}

/*
    @Rule

    @Category: Unit test

    @Description:
        function setPerformanceFee updates the state variable performanceFee using newPerformanceFee
*/
rule integrity_of_setPerformanceFee(uint256 newPerformanceFee) {
    env e;
    setPerformanceFee(e, newPerformanceFee);
    assert performanceFee() == newPerformanceFee;
}

/*
    @Rule

    @Category: Unit test

    @Description:
        function setFloatPercentage updates the state variable performanceFee with the value provided by the parameter newPerformanceFee
*/
rule integrity_of_setFloatPercentage(uint256 newFloatPercentage) {
    env e;
    setFloatPercentage(e, newFloatPercentage);
    assert floatPercentage() == newFloatPercentage;
}

/*
    @Rule

    @Category: Unit test

    @Description:
        function setTreasury updates the state variable treasury with the value provided by the parameter newTreasury
*/
rule integrity_of_setTreasury(address newTreasury) {
    env e;
    setTreasury(e, newTreasury);
    assert treasury() == newTreasury;
}

/*
    @Rule

    @Category: Unit test

    @Description:
        function setPerformanceFee reverts if the value of the parameter newPerformanceFee is greater than 10^18
*/
rule setPerformanceFee_reverts_if_newPerformanceFee_is_greater_than_1e18(uint256 newPerformanceFee) {
    require newPerformanceFee > 10^18;
    env e;
    setPerformanceFee@withrevert(e, newPerformanceFee);
    assert lastReverted;
}

/*
    @Rule

    @Category: Unit test

    @Description:
        function setFloatPercentage reverts if the value of the parameter newFloatPercentage is greater than 10^18
*/
rule setFloatPercentage_reverts_if_newFloatPercentage_is_greater_than_1e18(uint256 newFloatPercentage) {
    require newFloatPercentage > 10^18;
    env e;
    setFloatPercentage@withrevert(e, newFloatPercentage);
    assert lastReverted;
}

/*
    @Rule

    @Category: Unit test

    @Description:
        function setTreasury reverts if address(0)
*/
rule setTreasury_reverts_if_address_is_zero() {
    env e;
    setTreasury@withrevert(e, 0);
    assert lastReverted;
}

definition adminFunctions(method f) returns bool =
    f.selector == setSlippageTolerance(uint256).selector;

definition keeperFunctions(method f) returns bool =
    f.selector == applyNewTargetLtv(uint256).selector;


/*
    @Rule
    @Category: high level
    @Description:
        privileged functions should revert is the caller has no privilege
*/
rule privileged_functions_revert_if_no_priviledge(method f) 
filtered{f->adminFunctions(f) || keeperFunctions(f)} 
{
    env e;
    require adminFunctions(f) && !hasRole(DEFAULT_ADMIN_ROLE(), e.msg.sender)
            ||
            keeperFunctions(f) && !hasRole(KEEPER_ROLE(), e.msg.sender);

    calldataarg args;

    f@withrevert(e, args);

    assert lastReverted;
}

/*
    @Rule

    @Category: Variable transition

    @Description:
        function setSlippageTolerance should update slippageTolerance if _slippageTolerance <= ONE
*/
rule integrity_of_setSlippageTolerance(uint256 _slippageTolerance) {
    env e;
    require _slippageTolerance <= ONE();
    setSlippageTolerance(e, _slippageTolerance);
    assert slippageTolerance() == _slippageTolerance;
}
/*
    @Rule

    @Category: Unit test

    @Description:
        function setSlippageTolerance reverts if _slippageTolerance > ONE
*/
rule setSlippageTolerance_reverts_if_slippageTolerance_is_greater_than_ONE(uint256 _slippageTolerance) {
    env e;
    require _slippageTolerance > ONE();
    setSlippageTolerance@withrevert(e, _slippageTolerance);
    assert lastReverted;
}

/*
    @Rule

    @Category: High level

    @Description:
        function applyNewTargetLtv updates the state variable `slippageTolerance` with the value provided by `_newSlippageTolerance` and rebalances the Vault
*/
rule integrity_of_applyNewTargetLtv(uint256 _newTargetLtv) {
    env e;
    require _newTargetLtv <= getMaxLtv();
    applyNewTargetLtv(e, _newTargetLtv);
    assert targetLtv() == _newTargetLtv;
    // asserts of rebalance
}
/*
    @Rule

    @Category: Unit test

    @Description:
        function applyNewTargetLtv reverts if `_newTargetLtv` is greater than the maximum `LTV`
*/
rule applyNewTargetLtv_reverts_if_the_new_target_Ltv_is_greater_than_the_max_Ltv(uint256 _newTargetLtv) {
    env e;
    require _newTargetLtv > getMaxLtv();
    applyNewTargetLtv@withrevert(e, _newTargetLtv);
    assert lastReverted;
}

/*
    @Rule

    @Category: High level

    @Description:
        function rebalance should rebalance the vault's positions
*/
rule integrity_of_rebalance() {
    env e;

    uint256 _collateral = getCollateral();
    uint256 _invested = getInvested();
    uint256 _usdcBalance = getUsdcBalance();

    rebalance(e);

    assert getCollateral() >= _collateral;
    assert _invested >= getInvested();
    assert _usdcBalance >= getUsdcBalance();
}

definition delta(uint256 a, uint256 b) returns uint256 = (a > b  ? a - b : b - a);

definition percentDelta(uint256 a, uint256 b) returns uint256 = (b != 0 ? delta(a, b) * 1^18 / b : 0);

/*
    @Rule

    @Category: Medium level

    @Description:
        function rebalance should respect target Ltv percentage
*/
rule rebalance_respects_target_Ltv_percentage() {
    env e;

    require getLtv() == 0;

    rebalance(e);

    assert  targetLtv() == 0 => getLtv() == targetLtv()
            &&
            targetLtv() != 0 => percentDelta(getLtv(), targetLtv()) <= (1/100)^18;
}

/*
    @Rule

    @Category: High level

    @Description:
        function exitAllPositions should perform an emergency exit to release collateral if the vault is underwater
*/
rule exitAllPositions_performs_emergency_exit() { // Certora reported a time-out
    env e;
    uint256 _totalBefore = totalAssets();

    exitAllPositions(e);

    assert getCollateral() == 0;
    assert getDebt() == 0;
    assert percentDelta(getUsdcBalance(), _totalBefore) <= (1/100)^18;
}

/*
    @Rule

    @Category: High level

    @Description:
        function exitAllPositions should revert if the invested value is greater then or equal to the debt
*/
rule exitAllPositions_reverts_if_invested_is_greater_then_or_equal_to_debt() {
    env e;

    require getInvested() >= getDebt();

    exitAllPositions@withrevert(e);

    assert lastReverted;
}
