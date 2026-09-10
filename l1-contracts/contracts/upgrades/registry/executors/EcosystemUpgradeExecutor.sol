// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {ICoreRegistry} from "../objects/ICoreRegistry.sol";
import {ICTMTransition} from "../objects/ICTMTransition.sol";
import {ICTMUpgradeExecutor} from "./ICTMUpgradeExecutor.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {
    EcosystemLegNotNamedByTransition,
    EmptyBytes32,
    Unauthorized,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {CodehashPinLib} from "../libraries/CodehashPinLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";

/// @title EcosystemUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Domain-specific executor BOUND to the ecosystem `ProxyAdmin`: it owns that admin and
///         applies the shared-singleton implementation swaps pinned in write-once `CoreRegistry`
///         objects. Ecosystem authority is deliberately separate from CTM authority
///         (`CTMUpgradeExecutor`): a CTM is one of possibly many.
/// @dev Fixed logic, no generic delegatecall. Besides the owner, an AUTHORIZED `CTMUpgradeExecutor`
///      may drive `applyL1Upgrade` — but only for the registry its pending transition names, so
///      the ecosystem leg of an upgrade runs inside the CTM executor's stage lifecycle (ordered
///      before the CTM leg, exactly as the merged governance bundle ran it) without handing a CTM
///      executor any authority beyond that one leg. Authorization is explicit owner wiring, never
///      inferred from ownership shape: any contract can be constructed with the owner's address.
contract EcosystemUpgradeExecutor is UpgradeExecutorBase {
    using CodehashPinLib for address;

    /// @notice The ecosystem `ProxyAdmin` — admin of every shared singleton proxy. Owned by this
    ///         executor, so registry rows apply through the same authority that validates them.
    ProxyAdmin public immutable PROXY_ADMIN;

    /// @notice `EXTCODEHASH` of the audited `CoreRegistry`. Every registry this executor accepts
    ///         must run exactly that code (see `CTMUpgradeExecutor.TRANSITION_CODEHASH`).
    bytes32 public immutable CORE_REGISTRY_CODEHASH;

    /// @notice CTM executors allowed to drive the ecosystem leg of their own pending transition.
    mapping(address ctmExecutor => bool authorized) public isAuthorizedCTMExecutor;

    /// @notice Emitted after a registry's rows were applied through the bound admin.
    event L1UpgradeApplied(address indexed coreRegistry);

    /// @notice Emitted when a CTM executor's authorization to drive ecosystem legs changes.
    event CTMExecutorAuthorizationSet(address indexed ctmExecutor, bool authorized);

    constructor(
        address _initialOwner,
        ProxyAdmin _proxyAdmin,
        bytes32 _coreRegistryCodehash
    ) UpgradeExecutorBase(_initialOwner) {
        if (address(_proxyAdmin) == address(0)) {
            revert ZeroAddress();
        }
        if (_coreRegistryCodehash == bytes32(0)) {
            revert EmptyBytes32();
        }
        PROXY_ADMIN = _proxyAdmin;
        CORE_REGISTRY_CODEHASH = _coreRegistryCodehash;
    }

    /// @notice Grants or revokes a CTM executor's right to drive the ecosystem leg of its pending
    ///         transition (see {applyL1Upgrade}).
    /// @dev One explicit call per CTM executor, made by the owner when the CTM joins the model
    ///      (the bootstrap join) — never derived from the executor's shape or ownership.
    function setCTMExecutorAuthorization(address _ctmExecutor, bool _authorized) external onlyOwner {
        if (_ctmExecutor == address(0)) {
            revert ZeroAddress();
        }
        isAuthorizedCTMExecutor[_ctmExecutor] = _authorized;
        emit CTMExecutorAuthorizationSet(_ctmExecutor, _authorized);
    }

    /// @notice Applies a core registry's source-checked implementation swaps through the bound
    ///         `ProxyAdmin`.
    /// @dev Callable by the owner, or by an authorized CTM executor for exactly the registry its
    ///      pending transition names — the registry was reviewed as part of that transition.
    /// @param _coreRegistry The write-once registry approved by governance.
    function applyL1Upgrade(ICoreRegistry _coreRegistry) external {
        if (msg.sender != owner()) {
            _requireAuthorizedLeg(_coreRegistry);
        }
        address(_coreRegistry).requirePin(CORE_REGISTRY_CODEHASH);
        _coreRegistry.validate();
        // One call returns complete typed rows; no per-key rescans of the registry.
        ProxyUpgradeRowLib.applyRows(PROXY_ADMIN, _coreRegistry.ecosystemRows());
        emit L1UpgradeApplied(address(_coreRegistry));
    }

    /// @notice Reverts unless every row of `_coreRegistry` is applied: each proxy points at its
    ///         pinned `implNew`, read live through the bound `ProxyAdmin`. The stage-2 gate for
    ///         the same upgrade whose stage 1 ran `applyL1Upgrade`.
    /// @dev The row check describes one edge, not a standing invariant: a later upgrade moves
    ///      proxies past these rows and this then reverts by design.
    function validateUpgradeApplied(ICoreRegistry _coreRegistry) external view {
        address(_coreRegistry).requirePin(CORE_REGISTRY_CODEHASH);
        ProxyUpgradeRowLib.requireRowsApplied(PROXY_ADMIN, _coreRegistry.ecosystemRows());
    }

    /// @dev The caller must be an authorized CTM executor, and `_coreRegistry` must be the
    ///      ecosystem leg its PENDING transition names — an authorized executor with no pending
    ///      transition, or one naming another registry, gets nothing.
    function _requireAuthorizedLeg(ICoreRegistry _coreRegistry) private view {
        if (!isAuthorizedCTMExecutor[msg.sender]) {
            revert Unauthorized(msg.sender);
        }
        ICTMTransition pending = ICTMUpgradeExecutor(msg.sender).pendingTransition();
        if (address(pending) == address(0) || pending.coreRegistry() != address(_coreRegistry)) {
            revert EcosystemLegNotNamedByTransition(address(pending), address(_coreRegistry));
        }
    }
}
