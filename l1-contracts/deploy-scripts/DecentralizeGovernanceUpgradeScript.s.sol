// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Governance} from "contracts/governance/Governance.sol";
import {IStateTransitionManager} from "contracts/state-transition/IStateTransitionManager.sol";
import {Utils} from "./Utils.sol";

contract DecentralizeGovernanceUpgradeScript is Script {
    function upgradeSTM(
        ProxyAdmin _proxyAdmin,
        ITransparentUpgradeableProxy _stmProxy,
        Governance _governance,
        address _newStmImpl
    ) public {
        require(_proxyAdmin.getProxyAdmin(_stmProxy) == address(_proxyAdmin));
        require(_proxyAdmin.owner() == address(_governance));

        bytes memory proxyAdminUpgradeData = abi.encodeCall(ProxyAdmin.upgrade, (_stmProxy, _newStmImpl));

        Utils.executeUpgrade({
            _governor: address(_governance),
            _salt: bytes32(0),
            _target: address(_proxyAdmin),
            _data: proxyAdminUpgradeData,
            _value: 0,
            _delay: 0
        });
    }

    function setPendingAdmin(address _target, Governance _governance, address _pendingAdmin) public {
        bytes memory upgradeData = abi.encodeCall(IStateTransitionManager.setPendingAdmin, (_pendingAdmin));
        Utils.executeUpgrade({
            _governor: address(_governance),
            _salt: bytes32(0),
            _target: _target,
            _data: upgradeData,
            _value: 0,
            _delay: 0
        });
    }
}
