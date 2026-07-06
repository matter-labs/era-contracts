// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {EcosystemContract} from "./ContractIdentifiers.sol";
import {ICoreRegistry} from "./ICoreRegistry.sol";

/// @title EcosystemUpgradeModule
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A stateless orchestrator module for the ecosystem-wide (core) part of a protocol
///         upgrade: pointing every ecosystem proxy at its new implementation, as pinned by the
///         core registry.
/// @dev This contract is DELEGATECALLED by an `UpgradeExecutor` that must own the ecosystem
///      `ProxyAdmin`. Ecosystem authority is deliberately separate from CTM authority
///      (`CTMUpgradeModule`): the two scopes can be governed by different executors with
///      different owners and upgrade on different cadences. The module MUST remain stateless.
/// @dev The registry address is a *pinned implementation address* — the exact generated contract
///      governance approved — never a proxy, so what was signed is exactly what is read.
contract EcosystemUpgradeModule {
    /// @notice Emitted (from the executor's address) for every ecosystem proxy pointed at its new
    ///         implementation.
    event EcosystemContractUpgraded(EcosystemContract indexed contractId, address indexed proxy, address newImpl);

    /// @notice Points every ecosystem proxy at its new implementation, as pinned by the registry.
    ///         Contracts whose implementation is unchanged (or that have none pinned for the new
    ///         version) are skipped.
    /// @param _coreRegistry The pinned core-registry implementation approved by governance.
    function applyL1Upgrade(ICoreRegistry _coreRegistry) external {
        ProxyAdmin proxyAdmin = ProxyAdmin(_coreRegistry.proxyAdmin());
        uint256 oldProtocolVersion = _coreRegistry.oldProtocolVersion();
        uint256 newProtocolVersion = _coreRegistry.newProtocolVersion();

        EcosystemContract[] memory contracts = _coreRegistry.ecosystemContractList();
        uint256 contractsLength = contracts.length;
        for (uint256 i = 0; i < contractsLength; ++i) {
            address newImpl = _coreRegistry.implAddress(contracts[i], newProtocolVersion);
            if (newImpl == address(0) || newImpl == _coreRegistry.implAddress(contracts[i], oldProtocolVersion)) {
                continue;
            }
            address proxy = _coreRegistry.proxyAddress(contracts[i]);
            proxyAdmin.upgrade(ITransparentUpgradeableProxy(proxy), newImpl);
            emit EcosystemContractUpgraded(contracts[i], proxy, newImpl);
        }
    }
}
