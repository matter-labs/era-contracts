// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMContract} from "./ContractIdentifiers.sol";
import {ICTMRegistry} from "./ICTMRegistry.sol";
import {CTMUpgradeComposer} from "./CTMUpgradeComposer.sol";
import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {ProposedUpgrade} from "../../state-transition/libraries/ProposedUpgradeLib.sol";
import {IDefaultUpgrade} from "../IDefaultUpgrade.sol";

/// @title CTMUpgradeModule
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A stateless orchestrator module for the CTM-scoped part of a protocol upgrade: it
///         composes the upgrade cut, the L2 protocol upgrade transaction and the chain-creation
///         params from a per-CTM registry's constants and drives the ChainTypeManager with them.
/// @dev This contract is DELEGATECALLED by an `UpgradeExecutor` that must own the target
///      ChainTypeManager. CTM authority is deliberately separate from the ecosystem authority
///      (`EcosystemUpgradeModule`): each CTM can be governed by its own executor with its own
///      owner, and CTMs can upgrade on their own cadence without an ecosystem (core) registry.
///      The module MUST remain stateless: it declares no storage, and the executor verifies its
///      ownership slots after every run.
/// @dev The registry address each entrypoint takes is a *pinned implementation address* — the
///      exact generated contract governance approved — never a proxy, so what was signed is
///      exactly what is read.
contract CTMUpgradeModule {
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

    /// @notice Moves the registry's CTM to its new protocol version: sets the composed upgrade
    ///         cut (for existing chains) and the composed chain-creation params (for new chains)
    ///         from the same registry constants, so the two cannot drift apart.
    /// @param _registry The pinned per-CTM registry implementation approved by governance.
    /// @param _oldProtocolVersionDeadline The deadline until which the old protocol version stays
    ///        usable by chains that have not upgraded yet.
    /// @param _upgradeTimestamp The timestamp after which chains may execute the upgrade.
    function applyCTMUpgrade(
        ICTMRegistry _registry,
        uint256 _oldProtocolVersionDeadline,
        uint256 _upgradeTimestamp
    ) external {
        IChainTypeManager ctm = IChainTypeManager(_registry.ctmProxy());
        uint256 oldProtocolVersion = _registry.oldProtocolVersion();
        uint256 newProtocolVersion = _registry.newProtocolVersion();

        ctm.setNewVersionUpgrade({
            _cutData: _buildUpgradeCut(_registry, _upgradeTimestamp),
            _oldProtocolVersion: oldProtocolVersion,
            _oldProtocolVersionDeadline: _oldProtocolVersionDeadline,
            _newProtocolVersion: newProtocolVersion,
            _verifier: _registry.verifier(newProtocolVersion)
        });
        ctm.setChainCreationParams(CTMUpgradeComposer.buildChainCreationParams(_registry));

        emit CTMUpgradeApplied(address(ctm), address(_registry), oldProtocolVersion, newProtocolVersion);
    }

    /// @notice Upgrades a single chain diamond to the registry's new protocol version with the
    ///         same composed cut that `applyCTMUpgrade` committed to.
    /// @dev The cut is recomposed from the registry; since `upgradeChainFromVersion` checks it
    ///      against the stored `upgradeCutHash`, recomposition and commitment must agree — which
    ///      they do by construction, both deriving from the same constants.
    /// @param _upgradeTimestamp Must equal the value passed to `applyCTMUpgrade` (it is part of
    ///        the committed cut).
    function upgradeChain(ICTMRegistry _registry, uint256 _chainId, uint256 _upgradeTimestamp) external {
        IChainTypeManager ctm = IChainTypeManager(_registry.ctmProxy());

        ctm.upgradeChainFromVersion(
            _chainId,
            _registry.oldProtocolVersion(),
            _buildUpgradeCut(_registry, _upgradeTimestamp)
        );

        emit ChainUpgradeApplied(address(ctm), _chainId, _registry.newProtocolVersion());
    }

    /// @dev Composes the full upgrade cut: registry-diffed facet cuts with the
    ///      `DefaultUpgrade.upgrade(proposedUpgrade)` init delegatecall embedding the L2
    ///      protocol upgrade transaction.
    function _buildUpgradeCut(
        ICTMRegistry _registry,
        uint256 _upgradeTimestamp
    ) private view returns (Diamond.DiamondCutData memory) {
        ProposedUpgrade memory proposedUpgrade = CTMUpgradeComposer.buildProposedUpgrade(_registry, _upgradeTimestamp);
        return
            CTMUpgradeComposer.buildUpgradeCutData(
                _registry,
                _registry.ctmAddress(CTMContract.DefaultUpgrade, _registry.newProtocolVersion()),
                abi.encodeCall(IDefaultUpgrade.upgrade, (proposedUpgrade))
            );
    }
}
