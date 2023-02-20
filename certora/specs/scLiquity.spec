import "erc20.spec"

using MockLUSD as asset

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
}

rule converToShares_returns_the_same_value(uint256 assets) {
    env e;
    uint256 _shares = convertToShares(e, assets);
    env e2;
    require e2.msg.sender != e.msg.sender;
    uint256 shares_ = convertToShares(e2, assets);
    assert _shares == shares_;
}

rule convertToShares_gte_previewDeposit(uint256 assets) {
    env e;
    assert convertToShares(e, assets) >= previewDeposit(assets);
}

rule converToShares_rounds_down_towards_0(uint256 assets) {
    env e;
    require totalSupply() != 0;
    assert (assets * totalSupply()) / totalAssets() == convertToShares(e, assets);
}

rule converToAssets_returns_the_same_value(uint256 shares) {
    env e;
    uint256 _assets = convertToAssets(e, shares);
    env e2;
    require e2.msg.sender != e.msg.sender;
    uint256 assets_ = convertToAssets(e2, shares);
    assert _assets == assets_;
}

rule convertToAssets_lte_previewMint(uint256 shares) {
    env e;
    assert convertToAssets(e, shares) <= previewMint(shares);
}

rule convertToAssets_rounds_down_towards_0(uint256 shares) {
    env e;
    require totalSupply() != 0;
    assert (shares * totalAssets()) / totalSupply() == convertToAssets(e, shares);
}

rule maxDeposit_returns_correct_value(address receiver) {
    assert maxDeposit(receiver) == 2^256 - 1;
}

rule maxMint_returns_correct_value(address receiver) {
    assert maxMint(receiver) == 2^256 - 1;
}

rule previewDeposit_lte_deposit(uint256 assets, address receiver) {
    env e;
    assert previewDeposit(assets) <= deposit(e, assets, receiver);
}

rule previewMint_gte_mint(uint256 shares, address receiver) {
    env e;
    assert previewMint(shares) >= mint(e, shares, receiver);
}

rule previewWithdraw_gte_withdraw(uint256 assets, address receiver, address owner) {
    env e;
    assert previewWithdraw(assets) >= withdraw(e, assets, receiver, owner);
}

rule previewRedeem_lte_redeem(uint256 shares, address receiver, address owner) {
    env e;
    assert previewRedeem(shares) <= redeem(e, shares, receiver, owner);
}

// TODO depositWithPermit

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


rule deposit_reverts_if_not_enough_assets(uint256 assets, address receiver) {
    env e;
    uint256 userAssets = asset.balanceOf(e.msg.sender);
    require userAssets < assets;

    deposit@withrevert(e, assets, receiver);

    assert lastReverted;
}

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

rule withdraw_reverts_if_not_enough_assets(uint256 assets, address receiver, address owner) {
    require totalAssets() < assets;

    env e;
    withdraw@withrevert(e, assets, receiver, owner);

    assert lastReverted;
}

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

rule redeem_reverts_if_not_enough_shares(uint256 shares, address receiver, address owner) {
    env e;
    require balanceOf(owner) < shares || e.msg.sender != owner && allowance(owner, e.msg.sender) < shares;

    redeem@withrevert(e, shares, receiver, owner);

    assert lastReverted;
}

rule integrit_of_setPerformanceFee(uint256 newPerformanceFee) {
    env e;
    setPerformanceFee(e, newPerformanceFee);
    assert performanceFee() == newPerformanceFee;
}

rule integrity_of_setFloatPercentage(uint256 newFloatPercentage) {
    env e;
    setFloatPercentage(e, newFloatPercentage);
    assert floatPercentage() == newFloatPercentage;
}

rule integrity_of_setTreasury(address newTreasury) {
    env e;
    setTreasury(e, newTreasury);
    assert treasury() == newTreasury;
}

rule setPerformanceFee_reverts_if_newPerformanceFee_is_greater_than_1e18(uint256 newPerformanceFee) {
    require newPerformanceFee > 10^18;
    env e;
    setPerformanceFee@withrevert(e, newPerformanceFee);
    assert lastReverted;
}

rule setFloatPercentage_reverts_if_newFloatPercentage_is_greater_than_1e18(uint256 newFloatPercentage) {
    require newFloatPercentage > 10^18;
    env e;
    setFloatPercentage@withrevert(e, newFloatPercentage);
    assert lastReverted;
}

rule setTreasury_reverts_if_address_is_zero() {
    env e;
    setTreasury@withrevert(e, 0);
    assert lastReverted;
}
