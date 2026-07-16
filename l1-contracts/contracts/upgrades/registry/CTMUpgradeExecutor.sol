// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICTMTransition} from "./ICTMTransition.sol";
import {CTMUpgradeComposer} from "./CTMUpgradeComposer.sol";
import {UpgradeExecutorBase} from "../../governance/UpgradeExecutorBase.sol";
import {Diamond} from "../../state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "../../state-transition/IChainTypeManager.sol";
import {IDefaultUpgrade} from "../IDefaultUpgrade.sol";
import {TransitionReleaseMismatch} from "../../common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "../../state-transition/L1StateTransitionErrors.sol";

/// @title CTMUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain-specific executor for the CTM-scoped part of a protocol upgrade: it owns a
///         ChainTypeManager and drives the version bump, upgrade cut and chain upgrades from a
///         pinned, write-once `CTMTransition`. CTM authority is deliberately separate from
///         ecosystem authority (`EcosystemUpgradeExecutor`): each CTM can be governed by its own
///         executor with its own owner and upgrade on its own cadence.
/// @dev Unlike the previous generic `UpgradeExecutor` + delegatecalled module, this executor has
///      FIXED logic and calls the CTM directly (it is the CTM's owner). There is no permanent
///      arbitrary-`delegatecall` surface; `forward` (from the base) remains for emergencies.
/// @dev The transition each entrypoint takes is a *pinned implementation address* — the exact
///      generated contract governance approved — never a proxy, so what was signed is exactly
///      what is read.
contract CTMUpgradeExecutor is UpgradeExecutorBase {
    /// @notice Emitted after the owned CTM was moved to the transition's new protocol version.
    event CTMUpgradeApplied(
        address indexed ctm,
        address indexed transition,
        uint256 oldProtocolVersion,
        uint256 newProtocolVersion
    );

    /// @notice Emitted after a chain diamond was upgraded.
    event ChainUpgradeApplied(address indexed ctm, uint256 indexed chainId, uint256 newProtocolVersion);

    constructor(address _initialOwner) UpgradeExecutorBase(_initialOwner) {}

    /// @notice Installs the transition and points new-chain genesis at its target release.
    /// @dev Both transition edges are asserted independently BEFORE any mutation:
    ///      - the release edge (`currentRelease == fromRelease`) rejects execution from the wrong
    ///        release, and — since `applyCTMUpgrade` moves `currentRelease` — rejects replays;
    ///      - the version edge (`protocolVersion == oldProtocolVersion`) rejects the wrong
    ///        version schedule (also re-checked inside `setNewVersionUpgrade`).
    ///      A zero `fromRelease` is MIGRATION-ONLY semantics: it matches only a pre-registry CTM
    ///      (whose `currentRelease` is still unset, e.g. the v31 -> v32 hop). Because this call
    ///      always pins a non-zero `newRelease`, a zero-`fromRelease` transition can never apply
    ///      again once any release is installed — zero has no permanent meaning.
    /// @param _transition The write-once transition approved by governance.
    function applyCTMUpgrade(ICTMTransition _transition) external onlyOwner {
        _transition.validate();
        IChainTypeManager ctm = IChainTypeManager(_transition.ctmProxy());

        // Pin the release edge: the CTM must currently be at exactly the release this transition
        // departs from, so "how A becomes B" is never identified by version number alone.
        address currentRelease = ctm.currentRelease();
        if (currentRelease != _transition.fromRelease()) {
            revert TransitionReleaseMismatch(_transition.fromRelease(), currentRelease);
        }

        uint256 oldProtocolVersion = _transition.oldProtocolVersion();
        uint256 newProtocolVersion = _transition.newProtocolVersion();

        // Pin the version edge as well, independently of the release edge.
        uint256 currentProtocolVersion = ctm.protocolVersion();
        if (currentProtocolVersion != oldProtocolVersion) {
            revert OutdatedProtocolVersion(currentProtocolVersion, oldProtocolVersion);
        }

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

    /// @notice Upgrades a single chain diamond to the transition's new protocol version with the
    ///         same composed cut that `applyCTMUpgrade` committed to.
    /// @dev The cut is recomposed from the transition; since `upgradeChainFromVersion` checks it
    ///      against the stored `upgradeCutHash`, recomposition and commitment must agree — which
    ///      they do by construction, both deriving from the same pinned transition.
    /// @param _transition The same transition committed by `applyCTMUpgrade`.
    /// @param _chainId The chain to upgrade.
    function upgradeChain(ICTMTransition _transition, uint256 _chainId) external onlyOwner {
        _transition.validate();
        IChainTypeManager ctm = IChainTypeManager(_transition.ctmProxy());

        ctm.upgradeChainFromVersion(_chainId, _transition.oldProtocolVersion(), _buildUpgradeCut(_transition));

        emit ChainUpgradeApplied(address(ctm), _chainId, _transition.newProtocolVersion());
    }

    /// @dev Composes the upgrade cut: a `DefaultUpgrade.upgradeFromTransition(transition)` init
    ///      delegatecall (no outer `facetCuts` — the upgrade contract applies the facet swaps
    ///      itself, reading them from the same transition). The cut is chain-independent, so a
    ///      single cut is committed once and applied to every chain.
    function _buildUpgradeCut(ICTMTransition _transition) private view returns (Diamond.DiamondCutData memory) {
        return
            CTMUpgradeComposer.buildUpgradeCutData(
                _transition.defaultUpgrade(),
                abi.encodeCall(IDefaultUpgrade.upgradeFromTransition, (address(_transition)))
            );
    }
}
