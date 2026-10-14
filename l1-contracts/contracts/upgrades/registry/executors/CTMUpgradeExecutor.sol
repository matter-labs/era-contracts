// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {IEcosystemUpgradeOperation} from "../objects/IEcosystemUpgradeOperation.sol";
import {ICTMUpgradeExecutor} from "./ICTMUpgradeExecutor.sol";
import {DomainUpgradeExecutorBase} from "./DomainUpgradeExecutorBase.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {IBridgehubBase} from "../../../core/bridgehub/IBridgehubBase.sol";
import {IChainAssetHandlerBase} from "../../../core/chain-asset-handler/IChainAssetHandler.sol";
import {
    MigrationsNotPaused,
    ExecutorCoordinatorMismatch,
    OperationCarriesNoTransition,
    OperationManifestChanged,
    TransitionNotCommitted,
    TransitionReleaseMismatch,
    UpgradeNotPermissionlessYet,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "../../../state-transition/L1StateTransitionErrors.sol";
import {ProtocolVersionTooSmall} from "../../ZkSyncUpgradeErrors.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {CTM_CONTRACT_COUNT} from "../libraries/ContractIdentifiers.sol";
import {OperationManifest} from "../RegistryTypes.sol";
import {L2PlanLib} from "../libraries/L2PlanLib.sol";
import {BytecodesSupplier} from "../../BytecodesSupplier.sol";
import {IEcosystemUpgradeExecutor} from "./IEcosystemUpgradeExecutor.sol";

/// @title CTMUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain executor BOUND to one immutable ChainTypeManager: it owns that CTM and its
///         `ProxyAdmin`, and applies pinned, write-once `CTMTransition`s to it on the coordinating
///         `EcosystemUpgradeExecutor`'s instructions — reserve, apply, complete — plus the
///         per-chain `upgradeChain`. See {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Fixed logic, no generic delegatecall. The transition it reserves is the exact deployed
///      object governance approved, never a proxy. The fixed entrypoints are the upgrade lifecycle and `upgradeChain`; every other
///      owner operation of the CTM (freezing a chain, moving a deadline, replacing a committed
///      transition, ...) goes through the owner-gated, event-logged `forward`.
contract CTMUpgradeExecutor is DomainUpgradeExecutorBase, ICTMUpgradeExecutor {
    using ObjectAnchorLib for address;

    /// @notice The one ChainTypeManager this executor governs. Transitions carry no CTM pointer;
    ///         the binding is this immutable, so a transition cannot be aimed at a foreign CTM.
    IChainTypeManager public immutable CHAIN_TYPE_MANAGER;

    /// @notice The CTM DOMAIN's `ProxyAdmin` — the admin of the CTM proxy itself and of the
    ///         per-CTM proxies under the CTM's own administration. Owned by this executor, so an
    ///         operation's infrastructure rows apply through the same authority that commits its
    ///         transition.
    ProxyAdmin public immutable CTM_PROXY_ADMIN;

    /// @inheritdoc ICTMUpgradeExecutor
    ICTMTransition public reservedTransition;

    /// @dev `keccak256(abi.encode(manifest))` of the manifest `beginOperation` reserved:
    ///      `applyOperation` applies that manifest and no other.
    bytes32 internal reservedManifestHash;

    constructor(
        address _initialOwner,
        IChainTypeManager _ctm,
        ProxyAdmin _ctmProxyAdmin,
        address _coordinator
    ) DomainUpgradeExecutorBase(_initialOwner, _coordinator) {
        if (address(_ctm) == address(0) || address(_ctmProxyAdmin) == address(0) || _coordinator == address(0)) {
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
    /// @dev The rows go FIRST — the commit may need setters that only exist on the implementation
    ///      this very operation installs — and any failure reverts the coordinator's whole stage,
    ///      so a failed row leg cannot leave a version commit standing.
    function applyOperation(OperationManifest calldata _manifest) external onlyCoordinator {
        _requireActive();
        bytes32 supplied = keccak256(abi.encode(_manifest));
        if (supplied != reservedManifestHash) {
            revert OperationManifestChanged(reservedManifestHash, supplied);
        }
        // Checked here for a clear failure; the CTM's own version commit refuses to run unpaused.
        if (!_chainAssetHandler().migrationPausedFor(address(CHAIN_TYPE_MANAGER))) {
            revert MigrationsNotPaused();
        }
        ProxyUpgradeRowLib.applyRows(
            CTM_PROXY_ADMIN,
            ProxyUpgradeRowLib.toRows(_manifest.ctmInfrastructure, CTM_CONTRACT_COUNT)
        );
        ICTMTransition transition = reservedTransition;
        if (address(transition) != address(0)) {
            _applyCTMUpgrade(transition);
            _requireDepartureCommitted(transition);
        }
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function releaseMigrationPause() external onlyCoordinator {
        _requireIdle();
        _chainAssetHandler().unpauseCTMMigration(address(CHAIN_TYPE_MANAGER));
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function validateTransitionApplied(ICTMTransition _transition) external view {
        _requireTransitionDeployed(_transition);
        _requireTransitionApplied(_transition);
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function validateOperationApplied(IEcosystemUpgradeOperation _operation) external view {
        ICTMTransition transition = ICTMTransition(_operation.getManifest().ctmTransition);
        if (address(transition) == address(0)) {
            revert OperationCarriesNoTransition(address(_operation));
        }
        _requireTransitionDeployed(transition);
        _requireDepartureCommitted(transition);
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

    /// @dev Code presence only — a call to a codeless address succeeds silently. Provenance is
    ///      governance's review: see "Provenance and validation" in {docs/registry-driven-upgrades.md}.
    function _requireTransitionDeployed(ICTMTransition _transition) private view {
        address(_transition).requireCode();
    }

    /// @dev The coordinator binds this executor; the manifest supplies both halves of the leg.
    ///      Migrations are paused for an infrastructure-only leg too — see "Pause policy" in
    ///      {protocol-docs/ecosystem-upgrade-coordination.md}.
    function _reserveLeg(OperationManifest calldata _manifest) internal override returns (address) {
        address boundExecutor = address(IEcosystemUpgradeExecutor(coordinator).ctmExecutor());
        if (boundExecutor != address(this)) {
            revert ExecutorCoordinatorMismatch(address(this), boundExecutor);
        }
        ProxyUpgradeRowLib.requireRowCode(ProxyUpgradeRowLib.toRows(_manifest.ctmInfrastructure, CTM_CONTRACT_COUNT));
        ICTMTransition transition = ICTMTransition(_manifest.ctmTransition);
        if (address(transition) != address(0)) {
            _requireTransitionDeployed(transition);
            transition.validate();
            _requireEdges(transition);
        }
        reservedTransition = transition;
        reservedManifestHash = keccak256(abi.encode(_manifest));
        _chainAssetHandler().pauseCTMMigration(address(CHAIN_TYPE_MANAGER));
        return address(transition);
    }

    function _releaseLeg() internal override {
        delete reservedTransition;
        delete reservedManifestHash;
    }

    /// @dev Completion lifts the migration pause `beginOperation` took.
    function _afterCompletion() internal override {
        _chainAssetHandler().unpauseCTMMigration(address(CHAIN_TYPE_MANAGER));
    }

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

    /// @dev The CTM leg: installs the transition and points new-chain genesis at its target
    ///      release. Private by design — the lifecycle cannot be bypassed.
    function _applyCTMUpgrade(ICTMTransition _transition) private {
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

    /// @dev The departure `_original` committed is still committed: by `_original` itself, or by
    ///      a replacement of it ({IChainTypeManager.replaceUpgradeTransition}) — same source
    ///      release, landing no earlier — and the CTM has reached the effective target.
    function _requireDepartureCommitted(ICTMTransition _original) private view {
        uint256 oldProtocolVersion = _original.oldProtocolVersion();
        address committed = CHAIN_TYPE_MANAGER.upgradeTransition(oldProtocolVersion);
        if (committed == address(0)) {
            revert TransitionNotCommitted(address(_original), committed);
        }
        uint256 targetVersion = _original.newProtocolVersion();
        if (committed != address(_original)) {
            ICTMTransition effective = ICTMTransition(committed);
            address source = _original.fromRelease();
            address effectiveSource = effective.fromRelease();
            if (effectiveSource != source) {
                revert TransitionReleaseMismatch(source, effectiveSource);
            }
            uint256 effectiveTargetVersion = effective.newProtocolVersion();
            if (effectiveTargetVersion < targetVersion) {
                revert ProtocolVersionTooSmall(targetVersion, effectiveTargetVersion);
            }
            targetVersion = effectiveTargetVersion;
        }
        uint256 currentProtocolVersion = CHAIN_TYPE_MANAGER.protocolVersion();
        if (currentProtocolVersion < targetVersion) {
            revert OutdatedProtocolVersion(currentProtocolVersion, targetVersion);
        }
    }

    function _requireTransitionApplied(ICTMTransition _transition) private view {
        uint256 oldProtocolVersion = _transition.oldProtocolVersion();
        address committed = CHAIN_TYPE_MANAGER.upgradeTransition(oldProtocolVersion);
        if (committed != address(_transition)) {
            revert TransitionNotCommitted(address(_transition), committed);
        }
        uint256 newProtocolVersion = _transition.newProtocolVersion();
        uint256 currentProtocolVersion = CHAIN_TYPE_MANAGER.protocolVersion();
        if (currentProtocolVersion < newProtocolVersion) {
            revert OutdatedProtocolVersion(currentProtocolVersion, newProtocolVersion);
        }
    }

    /// @dev The shared ChainAssetHandler, read from the bound CTM's Bridgehub.
    function _chainAssetHandler() private view returns (IChainAssetHandlerBase) {
        return IChainAssetHandlerBase(IBridgehubBase(CHAIN_TYPE_MANAGER.BRIDGE_HUB()).chainAssetHandler());
    }
}
