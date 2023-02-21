import "erc20.spec"

using MockLUSD as asset
using MockPriceFeed as priceFeed

methods {
    // state modifying functions
    depositIntoStrategy()
    harvest(uint256 _lqtyAmount, bytes _lqtySwapData, uint256 _ethAmount, bytes _ethSwapData)
    setPerformanceFee(uint256 newPerformanceFee)
    setFloatPercentage(uint256 newFloatPercentage)
    setTreasury(address newTreasury)
    depositWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
    deposit(uint256 assets, address receiver) returns (uint256)
    mint(uint256 shares, address receiver) returns (uint256)
    withdraw(uint256 assets, address receiver, address owner) returns (uint256)
    redeem(uint256 shares, address receiver, address owner) returns (uint256)
    approve(address spender, uint256 amount) returns (bool)
    transfer(address to, uint256 amount) returns (bool)
    transferFrom(address from, address to, uint256 amount) returns (bool)
    permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
    grantRole(bytes32 role, address account)
    revokeRole(bytes32 role, address account)
    renounceRole(bytes32 role, address account)

    // view functions
    convertToShares(uint256 assets) returns (uint256) // omit envfree for some rules
    convertToAssets(uint256 shares) returns (uint256) // omit envfree for some rules
    totalAssets() returns (uint256) envfree
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

    // state variables
    totalInvested() returns (uint256) envfree
    totalProfit() returns (uint256) envfree
    stabilityPool() returns (address) envfree
    lusd2eth() returns (address) envfree
    lqty() returns (address) envfree
    performanceFee() returns (uint256) envfree
    floatPercentage() returns (uint256) envfree
    treasury() returns (address) envfree
    nonces(address) returns (uint256) envfree

   // state constants
    KEEPER_ROLE() returns (bytes32) envfree
    asset() returns (address) envfree
    DEFAULT_ADMIN_ROLE() returns (bytes32) envfree

    // erc20
    currentContract.totalSupply() returns (uint256) envfree
    currentContract.balanceOf(address) returns (uint256) envfree
    currentContract.allowance(address, address) returns (uint256) envfree
    asset.totalSupply() returns (uint256) envfree
    asset.balanceOf(address) returns (uint256) envfree
    priceFeed.latestAnswer() returns (int256) envfree
}

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
    f.selector != harvest(uint256, bytes, uint256, bytes).selector
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
    require e.msg.sender != stabilityPool();
    require receiver != currentContract;

    uint256 _totalAssets = totalAssets();
    require _totalAssets == 0 <=> totalSupply() == 0;

    require priceFeed.latestAnswer() == 0; // make sure no capital gain

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
rule converToAssets_returns_the_same_value(uint256 shares) {
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
    require e.msg.sender != stabilityPool();
    require receiver != currentContract;
    
    uint256 _userAssets = asset.balanceOf(e.msg.sender);
    uint256 _totalAssets = totalAssets();
    require _totalAssets + assets <= asset.totalSupply();
    uint256 _receiverShares = balanceOf(receiver);

    uint256 shares = deposit(e, assets, receiver);

    require _receiverShares + shares <= totalSupply();

    uint256 userAssets_ = asset.balanceOf(e.msg.sender);
    uint256 totalAssets_ = totalAssets();
    uint256 receiverShares_ = balanceOf(receiver);

    assert _userAssets - assets == userAssets_;
    assert _totalAssets + assets == totalAssets_;
    assert _receiverShares + shares == receiverShares_;
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
    require e.msg.sender != stabilityPool();
    require receiver != currentContract;

    uint256 _userAssets = asset.balanceOf(e.msg.sender);
    uint256 _totalAssets = totalAssets();
    uint256 _receiverShares = balanceOf(receiver);
    require _receiverShares + shares <= totalSupply();

    uint256 assets = mint(e, shares, receiver);
    require _totalAssets + assets <= asset.totalSupply();

    uint256 userAssets_ = asset.balanceOf(e.msg.sender);
    uint256 totalAssets_ = totalAssets();
    uint256 receiverShares_ = balanceOf(receiver);

    assert _userAssets - assets == userAssets_;
    assert _totalAssets + assets == totalAssets_;
    assert _receiverShares + shares == receiverShares_;
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
    require receiver != stabilityPool();

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
    require totalAssets() < assets;

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
    uint256 _totalAssets = totalAssets();
    uint256 _ownerShares = balanceOf(owner);
    uint256 _senderAllowance = allowance(owner, e.msg.sender);

    require e.msg.sender != currentContract;
    require receiver != currentContract;
    require receiver != stabilityPool();

    uint256 assets = redeem(e, shares, receiver, owner);
    require _receiverAssets + assets <= asset.totalSupply();

    uint256 totalAssets_ = totalAssets();
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
        function setPerformanceFee updates the state variable performanceFee using newPerformanceFee
*/
rule integrit_of_setPerformanceFee(uint256 newPerformanceFee) {
    env e;
    setPerformanceFee(e, newPerformanceFee);
    assert performanceFee() == newPerformanceFee;
}

/*
    @Rule

    @Category: To be filled

    @Description:
        To be filled
*/
rule integrity_of_setFloatPercentage(uint256 newFloatPercentage) {
    env e;
    setFloatPercentage(e, newFloatPercentage);
    assert floatPercentage() == newFloatPercentage;
}

/*
    @Rule

    @Category: To be filled

    @Description:
        To be filled
*/
rule integrity_of_setTreasury(address newTreasury) {
    env e;
    setTreasury(e, newTreasury);
    assert treasury() == newTreasury;
}

/*
    @Rule

    @Category: To be filled

    @Description:
        To be filled
*/
rule setPerformanceFee_reverts_if_newPerformanceFee_is_greater_than_1e18(uint256 newPerformanceFee) {
    require newPerformanceFee > 10^18;
    env e;
    setPerformanceFee@withrevert(e, newPerformanceFee);
    assert lastReverted;
}

/*
    @Rule

    @Category: To be filled

    @Description:
        To be filled
*/
rule setFloatPercentage_reverts_if_newFloatPercentage_is_greater_than_1e18(uint256 newFloatPercentage) {
    require newFloatPercentage > 10^18;
    env e;
    setFloatPercentage@withrevert(e, newFloatPercentage);
    assert lastReverted;
}

/*
    @Rule

    @Category: To be filled

    @Description:
        To be filled
*/
rule setTreasury_reverts_if_address_is_zero() {
    env e;
    setTreasury@withrevert(e, 0);
    assert lastReverted;
}
