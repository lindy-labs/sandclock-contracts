import "erc20.spec"

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
    totalSupply() returns (uint256) envfree

   // state constants
    KEEPER_ROLE() returns (bytes32) envfree
    asset() returns (address) envfree
    DEFAULT_ADMIN_ROLE() returns (bytes32) envfree
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

// TODO `convertToShares(uint256 assets)` should round down towards 0
rule converToShares_rounds_down_towards_0(uint256 assets) {
    env e;
    require totalSupply() != 0;
    assert (assets * totalSupply()) / totalAssets() == convertToShares(e, assets); // To revise...
}

rule converToAssets_returns_the_same_value(uint256 shares) {
    env e;
    uint256 _assets = convertToAssets(e, shares);
    env e2;
    require e2.msg.sender != e.msg.sender;
    uint256 assets_ = convertToAssets(e2, shares);
    assert _assets == assets_;
}

rule convertToAssets_gte_previewMint(uint256 shares) {
    env e;
    assert convertToAssets(e, shares) >= previewMint(shares);
}

// TODO `convertToAssets(uint256 shares)` should round down towards 0
rule convertToAssets_rounds_down_towards_0(uint256 shares) {
    env e;
    require totalSupply() != 0;
    assert (shares * totalAssets()) / totalSupply() == convertToAssets(e, shares); // To revise...
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

rule integrityOfdeposit(uint256 assets, address receiver) { // Revise
    env e;
    uint256 amount;
    underlying.mint(currentContract, amount);
    underlying.approve(address(vault), amount);

    uint256 preDepositBal = underlying.balanceOf(currentContract);

    deposit(amount, currentContract);

    assert convertToAssets(10 ** vault.decimals()) == 10^18;
    assert totalInvested() == amount - amount.mulWadDown(vault.floatPercentage());
    assert totalAssets() == amount;
    assert balanceOf(currentContract) == amount;
    assert convertToAssets(vault.balanceOf(currentContract)) == amount;
    assert underlying.balanceOf(currentContract) == preDepositBal - amount;
}


rule integrityOfwithdraw(uint256 assets, address receiver, address owner) { // Revise
    env e;
    uint256 amount;
    underlying.mint(currentContract, amount);
    underlying.approve(vault, amount);

    uint256 preDepositBal = underlying.balanceOf(currentContract);

    withdraw(amount, currentContract, currentContract);

    assert convertToAssets(10 ** vault.decimals()) == 10^18;
    assert totalInvested() == 0;
    assert totalAssets() == 0;
    assert balanceOf(currentContract) == 0;
    assert convertToAssets(vault.balanceOf(currentContract)) == 0;
    assert underlying.balanceOf(currentContract) == preDepositBal;
}

rule integrityOfsetPerformanceFee(uint256 newPerformanceFee) {
    env e;
    setPerformanceFee(e, newPerformanceFee);
    assert performanceFee() == newPerformanceFee;
}

rule integrityOfsetFloatPercentage(uint256 newFloatPercentage) {
    env e;
    setFloatPercentage(e, newFloatPercentage);
    assert floatPercentage() == newFloatPercentage;
}

rule integrityOfsetTreasury(address newTreasury) {
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
    env e;
    setFloatPercentage@withrevert(e, newFloatPercentage);
    assert lastReverted;
}

rule setTreasury_reverts_if_address_is_zero() {
    env e;
    setTreasury@withrevert(e, 0);
    assert lastReverted;
}
