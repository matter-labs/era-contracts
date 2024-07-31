// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2 as console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Governance} from "contracts/governance/Governance.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {Utils} from "./Utils.sol";

contract DecentralizeGovernanceUpgradeScript is Script {
    function upgradeSTM(ProxyAdmin _proxyAdmin, ITransparentUpgradeableProxy _stmProxy, Governance _governance, address _newStmImpl) public {
        require(_proxyAdmin.getProxyAdmin(_stmProxy) == address(_proxyAdmin));
        require(_proxyAdmin.owner() == address(_governance));

        bytes memory proxyAdminUpgradeData = abi.encodeCall(ProxyAdmin.upgrade, (_stmProxy, _newStmImpl));
        Utils.executeUpgrade(address(_governance), bytes32(0), address(_proxyAdmin), proxyAdminUpgradeData, 0, 0);
    }

    function setPendingAdmin(address _target, Governance _governance, address _pendingAdmin) public {
        bytes memory upgradeData = abi.encodeCall(IStateTransitionManager.setPendingAdmin, (_pendingAdmin));
        Utils.executeUpgrade(address(_governance), bytes32(0), _target, upgradeData, 0, 0);
    }
}
