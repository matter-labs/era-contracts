// SPDX-License-Identifier: MIT
// solhint-disable reason-string, gas-custom-errors
pragma solidity 0.8.24;

import {Script} from "forge-std/Script.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

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
        // solhint-disable-next-line gas-custom-errors
        require(_proxyAdmin.getProxyAdmin(_stmProxy) == address(_proxyAdmin), "Proxy admin incorrect");
        // solhint-disable-next-line gas-custom-errors
        require(_proxyAdmin.owner() == address(_governance), "Proxy admin owner incorrect");

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
