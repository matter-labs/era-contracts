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
    ///         Contracts with no new implementation pinned, or whose proxy already points at the
    ///         pinned implementation, are skipped.
    /// @dev The skip check compares against the LIVE implementation (read through the ecosystem
    ///      `ProxyAdmin`) rather than a registry-pinned old address. That live read is safe HERE
    ///      — unlike the CTM diamond cut, which is committed as a hash and must recompose
    ///      identically for the whole upgrade window (so it must never read live state), this
    ///      function reads and writes in one atomic transaction: the live implementation cannot
    ///      change between the check and the upgrade. It also makes the call idempotent.
    /// @param _coreRegistry The pinned core-registry implementation approved by governance.
    function applyL1Upgrade(ICoreRegistry _coreRegistry) external {
        ProxyAdmin proxyAdmin = ProxyAdmin(_coreRegistry.proxyAdmin());

        EcosystemContract[] memory contracts = _coreRegistry.ecosystemContractList();
        uint256 contractsLength = contracts.length;
        for (uint256 i = 0; i < contractsLength; ++i) {
            address newImpl = _coreRegistry.implAddress(contracts[i]);
            if (newImpl == address(0)) {
                continue;
            }
            ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(_coreRegistry.proxyAddress(contracts[i]));
            if (newImpl == proxyAdmin.getProxyImplementation(proxy)) {
                continue;
            }
            proxyAdmin.upgrade(proxy, newImpl);
            emit EcosystemContractUpgraded(contracts[i], address(proxy), newImpl);
        }
    }
}
