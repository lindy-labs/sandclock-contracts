// ERC20 functions
methods {
 function _.name()                                external /*returns (string) */   => DISPATCHER(true);
 function _.symbol()                              external /*returns (string) */   => DISPATCHER(true);
 function _.decimals()                            external /*returns (uint8) */    => DISPATCHER(true);
 function _.totalSupply()                         external /*returns(uint) */      => DISPATCHER(true);
 function _.balanceOf(address)                    external /*returns(uint) */      => DISPATCHER(true);
 function _.allowance(address,address)            external /*returns (uint256) */  => DISPATCHER(true);
 function _.approve(address,uint256)              external /*returns (bool)*/            => DISPATCHER(true);
 function _.transfer(address,uint256)             external /*returns (bool)*/            => DISPATCHER(true);
 function _.transferFrom(address,address,uint256) external /*returns (bool)*/            => DISPATCHER(true);
}