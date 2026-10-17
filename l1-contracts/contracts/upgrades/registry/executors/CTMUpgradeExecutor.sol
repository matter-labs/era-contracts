// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {IProxyUpgradeTransition} from "../objects/IProxyUpgradeTransition.sol";
import {ICTMUpgradeExecutor} from "./ICTMUpgradeExecutor.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {
    TransitionNotCommitted,
    TransitionReleaseMismatch,
    UpgradeNotPermissionlessYet,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "../../../state-transition/L1StateTransitionErrors.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {ProxyUpgradeDomain} from "../RegistryTypes.sol";
import {L2PlanLib} from "../libraries/L2PlanLib.sol";
import {BytecodesSupplier} from "../../BytecodesSupplier.sol";

/// @title CTMUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain executor BOUND to one immutable ChainTypeManager: it owns that CTM and its
///         `ProxyAdmin`, applies CTM-domain `ProxyUpgradeTransition` objects, commits write-once
///         `CTMTransition` objects on the CTM, and runs the per-chain `upgradeChain`. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Fixed logic, no generic delegatecall. The transition it commits is the exact deployed
///      object governance approved, never a proxy. Every other owner operation of the CTM (freezing
///      a chain, moving a deadline, replacing a committed transition, ...) goes through the
///      owner-gated, event-logged `forward`.
contract CTMUpgradeExecutor is UpgradeExecutorBase, ICTMUpgradeExecutor {
    using ObjectAnchorLib for address;

    /// @notice The one ChainTypeManager this executor governs. Transitions carry no CTM pointer;
    ///         the binding is this immutable, so a transition cannot be aimed at a foreign CTM
    ///         through this executor.
    IChainTypeManager public immutable CHAIN_TYPE_MANAGER;

    /// @notice The CTM DOMAIN's `ProxyAdmin` — the admin of the CTM proxy itself and of the
    ///         per-CTM proxies under the CTM's own administration. Owned by this executor.
    ProxyAdmin public immutable CTM_PROXY_ADMIN;

    constructor(
        address _initialOwner,
        IChainTypeManager _ctm,
        ProxyAdmin _ctmProxyAdmin
    ) UpgradeExecutorBase(_initialOwner) {
        if (address(_ctm) == address(0) || address(_ctmProxyAdmin) == address(0)) {
            revert ZeroAddress();
        }
        CHAIN_TYPE_MANAGER = _ctm;
        CTM_PROXY_ADMIN = _ctmProxyAdmin;
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function acceptCTMOwnership() external {
        Ownable2Step(address(CHAIN_TYPE_MANAGER)).acceptOwnership();
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function applyInfrastructureUpgrade(IProxyUpgradeTransition _infrastructureTransition) external onlyOwner {
        ProxyUpgradeRowLib.applyTransition(CTM_PROXY_ADMIN, _infrastructureTransition, ProxyUpgradeDomain.CTM);
        emit CTMInfrastructureUpgradeApplied(address(_infrastructureTransition));
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function applyCTMUpgrade(ICTMTransition _transition) external onlyOwner {
        _applyCTMUpgrade(_transition);
        _requireTransitionApplied(_transition);
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function validateTransitionApplied(ICTMTransition _transition) external view {
        address(_transition).requireCode();
        _requireTransitionApplied(_transition);
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function upgradeChain(ICTMTransition _transition, uint256 _chainId) external {
        uint256 oldProtocolVersion = _transition.oldProtocolVersion();
        if (msg.sender != owner() && msg.sender != CHAIN_TYPE_MANAGER.getChainAdmin(_chainId)) {
            uint256 deadline = CHAIN_TYPE_MANAGER.protocolVersionDeadline(oldProtocolVersion);
            if (block.timestamp <= deadline) {
                revert UpgradeNotPermissionlessYet(deadline);
            }
        }
        // The chain executes the cut its own CTM committed, so `_transition` must BE that
        // transition — otherwise the argument would name one edge while a different one ran.
        address committed = CHAIN_TYPE_MANAGER.upgradeTransition(oldProtocolVersion);
        if (committed != address(_transition)) {
            revert TransitionNotCommitted(address(_transition), committed);
        }
        // Deliberately NOT re-validated here — do not "restore" this: `validate()` re-reads code
        // existence that cannot have changed since the commit, and costs ~19 EXTCODESIZE reads
        // across both releases PER CHAIN on a function that is permissionless once the deadline
        // passes.
        CHAIN_TYPE_MANAGER.upgradeChainFromVersion(_chainId, oldProtocolVersion);
        emit ChainUpgradeApplied(_chainId, _transition.newProtocolVersion());
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    /// @dev Both transition edges, asserted independently (and both re-checked inside
    ///      `setNewVersionUpgradeFromTransition`):
    ///      - the release edge (`currentRelease == fromRelease`) rejects execution from the wrong
    ///        release, and — since the commit moves `currentRelease` — rejects replays;
    ///      - the version edge (`protocolVersion == oldProtocolVersion`) rejects the wrong
    ///        version schedule.
    function _requireEdges(
        ICTMTransition _transition
    ) private view returns (uint256 oldProtocolVersion, uint256 newProtocolVersion) {
        address currentRelease = CHAIN_TYPE_MANAGER.currentRelease();
        if (currentRelease != _transition.fromRelease()) {
            revert TransitionReleaseMismatch(_transition.fromRelease(), currentRelease);
        }
        oldProtocolVersion = _transition.oldProtocolVersion();
        newProtocolVersion = _transition.newProtocolVersion();
        uint256 currentProtocolVersion = CHAIN_TYPE_MANAGER.protocolVersion();
        if (currentProtocolVersion != oldProtocolVersion) {
            revert OutdatedProtocolVersion(currentProtocolVersion, oldProtocolVersion);
        }
    }

    /// @dev Installs the transition and points new-chain genesis at its target release.
    function _applyCTMUpgrade(ICTMTransition _transition) private {
        address(_transition).requireCode();
        _transition.validate();
        (uint256 oldProtocolVersion, uint256 newProtocolVersion) = _requireEdges(_transition);
        // Every bytecode the L2 transaction depends on must already be published on the CTM's
        // supplier — otherwise the committed edge fails on every chain's L2 leg.
        L2PlanLib.requirePublished(
            BytecodesSupplier(CHAIN_TYPE_MANAGER.L1_BYTECODES_SUPPLIER()),
            _transition.l2Plan().factoryDepHashes
        );
        // One argument, not four plus a cut: the CTM reads the version edge, the schedule, the cut
        // and the release it installs from the same pinned object, so they cannot be passed
        // inconsistently.
        CHAIN_TYPE_MANAGER.setNewVersionUpgradeFromTransition(_transition);
        emit CTMUpgradeApplied(address(_transition), oldProtocolVersion, newProtocolVersion);
    }

    function _requireTransitionApplied(ICTMTransition _transition) private view {
        uint256 oldProtocolVersion = _transition.oldProtocolVersion();
        address committed = CHAIN_TYPE_MANAGER.upgradeTransition(oldProtocolVersion);
        if (committed != address(_transition)) {
            revert TransitionNotCommitted(address(_transition), committed);
        }
        uint256 newProtocolVersion = _transition.newProtocolVersion();
        uint256 currentProtocolVersion = CHAIN_TYPE_MANAGER.protocolVersion();
        // Defense in depth: a committed edge's target is never ahead of `protocolVersion`.
        if (currentProtocolVersion < newProtocolVersion) {
            revert OutdatedProtocolVersion(currentProtocolVersion, newProtocolVersion);
        }
    }
}
