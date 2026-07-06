// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMContract, EcosystemContract} from "./ContractIdentifiers.sol";
import {ICoreRegistry} from "./ICoreRegistry.sol";
import {ICTMRegistry} from "./ICTMRegistry.sol";
import {UpgradeComposer} from "./UpgradeComposer.sol";
import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {ProposedUpgrade} from "../../state-transition/libraries/ProposedUpgradeLib.sol";
import {IDefaultUpgrade} from "../IDefaultUpgrade.sol";

/// @title RegistryUpgradeModule
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A stateless orchestrator module that performs the mechanical calls of a protocol
///         upgrade by composing every payload from registry constants at execution time.
/// @dev This contract is DELEGATECALLED by the `UpgradeExecutor`, so it acts with the executor's
///      identity — i.e. as the owner of the ChainTypeManagers and the ecosystem `ProxyAdmin`.
///      It MUST remain stateless: it declares no storage, and the executor verifies its ownership
///      slots after every run.
/// @dev The registry address each entrypoint takes is a *pinned implementation address* — the
///      exact generated contract governance approved — never a proxy, so what was signed is
///      exactly what is read.
contract RegistryUpgradeModule {
    /// @notice Emitted (from the executor's address) after a CTM was moved to the registry's new
    ///         protocol version.
    event CTMUpgradeApplied(
        address indexed ctm,
        address indexed ctmRegistry,
        uint256 oldProtocolVersion,
        uint256 newProtocolVersion
    );

    /// @notice Emitted (from the executor's address) after a chain diamond was upgraded.
    event ChainUpgradeApplied(address indexed ctm, uint256 indexed chainId, uint256 newProtocolVersion);

    /// @notice Emitted (from the executor's address) for every ecosystem proxy pointed at its new
    ///         implementation.
    event EcosystemContractUpgraded(EcosystemContract indexed contractId, address indexed proxy, address newImpl);

    /// @notice Moves a CTM to the registry's new protocol version: sets the composed upgrade cut
    ///         (for existing chains) and the composed chain-creation params (for new chains) from
    ///         the same registry constants, so the two cannot drift apart.
    /// @param _coreRegistry The pinned core-registry implementation approved by governance.
    /// @param _isZKsyncOS Which CTM to upgrade (false = Era, true = ZKsyncOS).
    /// @param _oldProtocolVersionDeadline The deadline until which the old protocol version stays
    ///        usable by chains that have not upgraded yet.
    /// @param _upgradeTimestamp The timestamp after which chains may execute the upgrade.
    function applyCTMUpgrade(
        ICoreRegistry _coreRegistry,
        bool _isZKsyncOS,
        uint256 _oldProtocolVersionDeadline,
        uint256 _upgradeTimestamp
    ) external {
        ICTMRegistry registry = ICTMRegistry(_coreRegistry.ctmRegistry(_isZKsyncOS));
        IChainTypeManager ctm = IChainTypeManager(registry.ctmProxy());
        uint256 oldProtocolVersion = registry.oldProtocolVersion();
        uint256 newProtocolVersion = registry.newProtocolVersion();

        ctm.setNewVersionUpgrade({
            _cutData: _buildUpgradeCut(registry, _upgradeTimestamp),
            _oldProtocolVersion: oldProtocolVersion,
            _oldProtocolVersionDeadline: _oldProtocolVersionDeadline,
            _newProtocolVersion: newProtocolVersion,
            _verifier: registry.verifier(newProtocolVersion)
        });
        ctm.setChainCreationParams(UpgradeComposer.buildChainCreationParams(registry));

        emit CTMUpgradeApplied(address(ctm), address(registry), oldProtocolVersion, newProtocolVersion);
    }

    /// @notice Upgrades a single chain diamond to the registry's new protocol version with the
    ///         same composed cut that `applyCTMUpgrade` committed to.
    /// @dev The cut is recomposed from the registry; since `upgradeChainFromVersion` checks it
    ///      against the stored `upgradeCutHash`, recomposition and commitment must agree — which
    ///      they do by construction, both deriving from the same constants.
    /// @param _upgradeTimestamp Must equal the value passed to `applyCTMUpgrade` (it is part of
    ///        the committed cut).
    function upgradeChain(
        ICoreRegistry _coreRegistry,
        bool _isZKsyncOS,
        uint256 _chainId,
        uint256 _upgradeTimestamp
    ) external {
        ICTMRegistry registry = ICTMRegistry(_coreRegistry.ctmRegistry(_isZKsyncOS));
        IChainTypeManager ctm = IChainTypeManager(registry.ctmProxy());

        ctm.upgradeChainFromVersion(
            _chainId,
            registry.oldProtocolVersion(),
            _buildUpgradeCut(registry, _upgradeTimestamp)
        );

        emit ChainUpgradeApplied(address(ctm), _chainId, registry.newProtocolVersion());
    }

    /// @notice Points every ecosystem proxy at its new implementation, as pinned by the registry.
    ///         Contracts whose implementation is unchanged (or that have none pinned for the new
    ///         version) are skipped.
    /// @dev Runs with the executor's identity, which must own the ecosystem `ProxyAdmin`.
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

    /// @dev Composes the full upgrade cut: registry-diffed facet cuts with the
    ///      `DefaultUpgrade.upgrade(proposedUpgrade)` init delegatecall embedding the L2
    ///      protocol upgrade transaction.
    function _buildUpgradeCut(
        ICTMRegistry _registry,
        uint256 _upgradeTimestamp
    ) private view returns (Diamond.DiamondCutData memory) {
        ProposedUpgrade memory proposedUpgrade = UpgradeComposer.buildProposedUpgrade(_registry, _upgradeTimestamp);
        return
            UpgradeComposer.buildUpgradeCutData(
                _registry,
                _registry.ctmAddress(CTMContract.DefaultUpgrade, _registry.newProtocolVersion()),
                abi.encodeCall(IDefaultUpgrade.upgrade, (proposedUpgrade))
            );
    }
}
