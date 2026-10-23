// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {IProxyUpgradeTransition} from "../objects/IProxyUpgradeTransition.sol";
import {ICTMUpgradeExecutor} from "./ICTMUpgradeExecutor.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {TransitionNotCommitted, Unauthorized, ZeroAddress} from "../../../common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "../../../state-transition/L1StateTransitionErrors.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {ProxyUpgradeDomain} from "../RegistryTypes.sol";

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
///      owner-gated, event-logged `forward`; freezing and unfreezing a chain the CTM also takes
///      from the Bridgehub's owner directly ({ChainTypeManager-freezeChain}).
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
        Ownable2Step ctm = Ownable2Step(address(CHAIN_TYPE_MANAGER));
        if (msg.sender != owner() && msg.sender != ctm.owner()) {
            revert Unauthorized(msg.sender);
        }
        ctm.acceptOwnership();
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function applyInfrastructureUpgrade(IProxyUpgradeTransition _infrastructureTransition) external onlyOwner {
        ProxyUpgradeRowLib.applyTransition(CTM_PROXY_ADMIN, _infrastructureTransition, ProxyUpgradeDomain.CTM);
        emit CTMInfrastructureUpgradeApplied(address(_infrastructureTransition));
    }

    /// @inheritdoc ICTMUpgradeExecutor
    /// @dev The commit's checks live in the CTM, so a commit sent through `forward` gets the same
    ///      ones.
    function applyCTMUpgrade(ICTMTransition _transition) external onlyOwner {
        address(_transition).requireCode();
        // One argument, not four plus a cut: the CTM reads the version edge, the schedule, the cut
        // and the release it installs from the same pinned object, so they cannot be passed
        // inconsistently.
        CHAIN_TYPE_MANAGER.setNewVersionUpgradeFromTransition(_transition);
        emit CTMUpgradeApplied(
            address(_transition),
            _transition.oldProtocolVersion(),
            _transition.newProtocolVersion()
        );
        _requireTransitionApplied(_transition);
    }

    /// @inheritdoc ICTMUpgradeExecutor
    function upgradeChain(ICTMTransition _transition, uint256 _chainId) external {
        if (msg.sender != owner() && msg.sender != CHAIN_TYPE_MANAGER.getChainAdmin(_chainId)) {
            revert Unauthorized(msg.sender);
        }
        uint256 oldProtocolVersion = _transition.oldProtocolVersion();
        // The chain executes the cut its own CTM committed, so `_transition` must BE that
        // transition — otherwise the argument would name one edge while a different one ran.
        address committed = CHAIN_TYPE_MANAGER.upgradeTransition(oldProtocolVersion);
        if (committed != address(_transition)) {
            revert TransitionNotCommitted(address(_transition), committed);
        }
        // Deliberately NOT re-validated here: the CTM checked the code the transition names when
        // it committed it, and that code cannot have gone since.
        CHAIN_TYPE_MANAGER.upgradeChainFromVersion(_chainId, oldProtocolVersion);
        emit ChainUpgradeApplied(_chainId, _transition.newProtocolVersion());
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
