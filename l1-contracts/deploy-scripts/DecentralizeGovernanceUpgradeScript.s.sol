// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Governance} from "contracts/governance/Governance.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Utils} from "./Utils.sol";
import {ProxyAdminIncorrect, ProxyAdminIncorrectOwner} from "./ZkSyncScriptErrors.sol";

contract DecentralizeGovernanceUpgradeScript is Script {
    function upgradeCTM(
        ProxyAdmin _proxyAdmin,
        ITransparentUpgradeableProxy _ctmProxy,
        Governance _governance,
        address _newCtmImpl
    ) public {
        if (_proxyAdmin.getProxyAdmin(_ctmProxy) != address(_proxyAdmin)) {
            revert ProxyAdminIncorrect(_proxyAdmin.getProxyAdmin(_ctmProxy), address(_proxyAdmin));
        }
        if (_proxyAdmin.owner() != address(_governance)) {
            revert ProxyAdminIncorrectOwner(_proxyAdmin.owner(), address(_governance));
        }

        bytes memory proxyAdminUpgradeData = abi.encodeCall(ProxyAdmin.upgrade, (_ctmProxy, _newCtmImpl));

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
        bytes memory upgradeData = abi.encodeCall(IChainTypeManager.setPendingAdmin, (_pendingAdmin));
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
