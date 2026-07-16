// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMTransition} from "./ICTMTransition.sol";
import {CTMUpgradeComposer} from "./CTMUpgradeComposer.sol";
import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {IDefaultUpgrade} from "../IDefaultUpgrade.sol";
import {TransitionReleaseMismatch} from "../../common/L1ContractErrors.sol";

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

    /// @notice Installs the transition and points new-chain genesis at its target release.
    /// @param _transition The write-once transition approved by governance.
    function applyCTMUpgrade(ICTMTransition _transition) external {
        _transition.validate();
        IChainTypeManager ctm = IChainTypeManager(_transition.ctmProxy());

        // Pin the release edge: the CTM must currently be at exactly the release this transition
        // departs from (`address(0)` for the first, pre-registry transition e.g. v31 -> v32), so
        // "how A becomes B" is never identified by version number alone.
        address currentRelease = ctm.currentRelease();
        if (currentRelease != _transition.fromRelease()) {
            revert TransitionReleaseMismatch(_transition.fromRelease(), currentRelease);
        }

        uint256 oldProtocolVersion = _transition.oldProtocolVersion();
        uint256 newProtocolVersion = _transition.newProtocolVersion();

        ctm.setNewVersionUpgrade({
            _cutData: _buildUpgradeCut(_transition),
            _oldProtocolVersion: oldProtocolVersion,
            _oldProtocolVersionDeadline: _transition.oldProtocolVersionDeadline(),
            _newProtocolVersion: newProtocolVersion,
            _verifier: _transition.verifier()
        });
        ctm.setCurrentRelease(_transition.newRelease());

        emit CTMUpgradeApplied(address(ctm), address(_transition), oldProtocolVersion, newProtocolVersion);
    }

    /// @notice Upgrades a single chain diamond to the registry's new protocol version with the
    ///         same composed cut that `applyCTMUpgrade` committed to.
    /// @dev The cut is recomposed from the registry; since `upgradeChainFromVersion` checks it
    ///      against the stored `upgradeCutHash`, recomposition and commitment must agree — which
    ///      they do by construction, both deriving from the same constants.
    /// @param _transition The same transition committed by `applyCTMUpgrade`.
    /// @param _chainId The chain to upgrade.
    function upgradeChain(ICTMTransition _transition, uint256 _chainId) external {
        _transition.validate();
        IChainTypeManager ctm = IChainTypeManager(_transition.ctmProxy());

        ctm.upgradeChainFromVersion(
            _chainId,
            _transition.oldProtocolVersion(),
            _buildUpgradeCut(_transition)
        );

        emit ChainUpgradeApplied(address(ctm), _chainId, _transition.newProtocolVersion());
    }

    /// @dev Composes the upgrade cut: a `DefaultUpgrade.upgradeFromRegistry(registry, timestamp)`
    ///      init delegatecall (no outer `facetCuts` — the upgrade contract applies the facet swaps
    ///      itself). The `ProposedUpgrade` is NOT embedded here: the executor composes it on-chain
    ///      from the same registry at execution time, so the committed cut carries only the registry
    ///      address and timestamp. Both remain chain-independent, so a single cut is committed once
    ///      and applied to every chain; per-chain L2-tx arguments are injected in the executor.
    function _buildUpgradeCut(
        ICTMTransition _transition
    ) private view returns (Diamond.DiamondCutData memory) {
        return
            CTMUpgradeComposer.buildUpgradeCutData(
                _transition.defaultUpgrade(),
                abi.encodeCall(IDefaultUpgrade.upgradeFromTransition, (address(_transition)))
            );
    }
}
