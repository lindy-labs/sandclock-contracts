// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/console2.sol";
import {CREATE3Script} from "../base/CREATE3Script.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";
import {WETH} from "solmate/tokens/WETH.sol";
import {AccessControl} from "openzeppelin-contracts/access/AccessControl.sol";
import {ERC4626} from "solmate/mixins/ERC4626.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";

import {MainnetAddresses} from "./MainnetAddresses.sol";
import {Constants as C} from "../../src/lib/Constants.sol";
import {ISwapRouter} from "../../src/interfaces/uniswap/ISwapRouter.sol";
import {sc4626} from "../../src/sc4626.sol";

/**
 * Mainnet base deployment file that handles deployment.
 */
abstract contract MainnetDeployBase is CREATE3Script {
    using SafeTransferLib for ERC20;

    address deployerAddress;
    address keeper;
    address multisig;

    WETH weth = WETH(payable(C.WETH));
    ERC20 usdc = ERC20(C.USDC);

    constructor() {
        _init();
    }

    function _init() internal virtual {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        require(deployerPrivateKey != 0, "Deployer private key not set");

        deployerAddress = vm.rememberKey(deployerPrivateKey);

        keeper = vm.envOr("KEEPER", MainnetAddresses.KEEPER);
        multisig = vm.envOr("MULTISIG", MainnetAddresses.MULTISIG);
    }

    function deployWithCreate3(string memory _name, bytes memory _creationCode) public returns (address deployed) {
        deployed = getCreate3Contract(deployerAddress, _name);

        if (deployed.code.length != 0) {
            console2.log("Existing", _name, ":", deployed);
        } else {
            create3.deploy(getCreate3ContractSalt(_name), _creationCode);
            console2.log("Deployed", _name, ":", deployed);
        }
    }

    function _transferAdminRoleToMultisig(AccessControl _contract) internal {
        _contract.grantRole(_contract.DEFAULT_ADMIN_ROLE(), multisig);
        _contract.revokeRole(_contract.DEFAULT_ADMIN_ROLE(), deployerAddress);
    }

    function _setTreasury(sc4626 _vault, address _treasury) internal {
        _vault.setTreasury(_treasury);
    }

    function _deposit(ERC4626 _vault, uint256 _amount) internal virtual {
        ERC20(_vault.asset()).safeApprove(address(_vault), _amount);
        _vault.deposit(_amount, deployerAddress);
    }
}
