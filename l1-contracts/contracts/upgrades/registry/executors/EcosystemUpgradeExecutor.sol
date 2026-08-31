// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ICoreRegistry} from "../objects/ICoreRegistry.sol";
import {IUpgradeInitDataProvider} from "../IUpgradeInit.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {EmptyBytes32, NoActiveRegistryUpgrade, ZeroAddress} from "../../../common/L1ContractErrors.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";

/// @title EcosystemUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain-specific executor BOUND to one immutable ecosystem `ProxyAdmin`: it owns that
///         admin and points every ecosystem proxy at its new implementation, as pinned by a
///         write-once core registry. Ecosystem authority is deliberately separate from CTM
///         authority (`CTMUpgradeExecutor`).
/// @dev Fixed logic, no generic delegatecall. The break-glass `forward` (base) is gated by a
///      SEPARATE governor. The registry address is a *pinned implementation address* — the exact
///      generated contract governance approved — never a proxy.
/// @dev The ecosystem is the SHARED singletons — bridges, Bridgehub, MessageRoot. Nothing
///      CTM-scoped is expressible here: the CTM's own implementation (and its per-CTM proxies)
///      upgrade through the transition's `ctmProxyRows`, under `CTMUpgradeExecutor`'s authority —
///      there may be several CTMs, each on its own cadence.
contract EcosystemUpgradeExecutor is UpgradeExecutorBase, IUpgradeInitDataProvider {
    using CodehashPinLib for address;

    /// @dev Nonzero only WHILE `applyL1Upgrade` applies its rows: the pinned registry whose
    ///      `initData` {upgradeInitData} serves to a reinitializing implementation. See
    ///      {IUpgradeInit.sol} for the msg.sender-based resolution path.
    ICoreRegistry private activeRegistry;

    /// @notice The one ecosystem `ProxyAdmin` this executor governs. Registries carry no proxy
    ///         admin pointer; the binding is this immutable.
    ProxyAdmin public immutable PROXY_ADMIN;

    /// @notice `EXTCODEHASH` of the audited `CoreRegistry` — see
    ///         `CTMUpgradeExecutor.TRANSITION_CODEHASH` for the provenance model.
    bytes32 public immutable CORE_REGISTRY_CODEHASH;

    constructor(
        address _initialOwner,
        address _emergencyUpgradeBoard,
        ProxyAdmin _proxyAdmin,
        bytes32 _coreRegistryCodehash
    ) UpgradeExecutorBase(_initialOwner, _emergencyUpgradeBoard) {
        if (address(_proxyAdmin) == address(0)) {
            revert ZeroAddress();
        }
        if (_coreRegistryCodehash == bytes32(0)) {
            revert EmptyBytes32();
        }
        PROXY_ADMIN = _proxyAdmin;
        CORE_REGISTRY_CODEHASH = _coreRegistryCodehash;
    }

    /// @notice Points every ecosystem proxy at its new implementation, as pinned by the registry.
    ///         Rows are SOURCE-CHECKED edges: a proxy already at `implNew` is skipped
    ///         (idempotence); a proxy at `expectedOldImpl` is upgraded; a proxy at anything else
    ///         reverts — replaying a stale registry can therefore never downgrade a proxy that a
    ///         later upgrade has already moved on.
    /// @dev The live read through the bound `ProxyAdmin` is safe here — unlike the CTM diamond
    ///      cut (committed as a hash for a whole upgrade window), this function reads and writes
    ///      in one atomic transaction.
    /// @param _coreRegistry The pinned core-registry implementation approved by governance.
    function applyL1Upgrade(ICoreRegistry _coreRegistry) external onlyOwner {
        address(_coreRegistry).requirePin(CORE_REGISTRY_CODEHASH);
        _coreRegistry.validate();

        // One call returns complete typed rows; no per-key rescans of the registry.
        activeRegistry = _coreRegistry;
        ProxyUpgradeRowLib.applyRows(PROXY_ADMIN, _coreRegistry.ecosystemRows());
        delete activeRegistry;
    }

    /// @inheritdoc IUpgradeInitDataProvider
    function upgradeInitData(address _proxy) external view returns (bytes memory) {
        ICoreRegistry registry = activeRegistry;
        if (address(registry) == address(0)) {
            revert NoActiveRegistryUpgrade();
        }
        return registry.upgradeInitData(_proxy);
    }
}
