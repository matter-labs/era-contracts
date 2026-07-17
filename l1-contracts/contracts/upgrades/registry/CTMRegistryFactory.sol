// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMRelease} from "./CTMRelease.sol";
import {CTMTransition} from "./CTMTransition.sol";
import {CoreRegistry} from "./CoreRegistry.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Factories that deploy and initialize a write-once registry object ({CTMRelease} /
///         {CTMTransition} / {CoreRegistry}) in a SINGLE transaction, idempotently per manifest
///         (`deployOrGet` semantics).
///
/// @dev Two failure modes are closed at once:
///      - FIRST-CALLER-WINS INIT: the registries have unauthenticated one-shot initializers, so
///        deploying and initializing in separate transactions would leave an uninitialized,
///        front-runnable instance on-chain. The factory does both in one transaction — no such
///        window ever exists.
///      - SAME-MANIFEST RACES: each factory keeps a `manifestHash -> instance` registry. If the
///        requested manifest was already deployed through this factory, the existing (already
///        verified, write-once) instance is returned instead of reverting — a front-runner using
///        the SAME manifest merely does the caller's work; a different manifest lands in a
///        different slot and cannot interfere.
///      Deterministic addresses are deliberately NOT part of the model (CREATE2 address
///      derivation differs between the EVM and EraVM, and nothing needs the address to be
///      predictable — the CTM stores the pointer); idempotence comes from the hash registry.
/// @dev One factory per registry type — NOT one combined factory: a factory's runtime code
///      embeds the creation bytecode of the contract it deploys, and all three together exceed
///      the EIP-170 runtime size limit on L1.
contract CTMReleaseFactory {
    /// @notice The instance deployed for each manifest hash (zero = not deployed yet).
    mapping(bytes32 manifestHash => address instance) public deployedFor;

    /// @notice Emitted once a release has been deployed and initialized atomically.
    event ReleaseDeployed(address indexed release, bytes32 manifestHash);

    /// @notice Deploys + initializes a {CTMRelease} for `_manifest`, or returns the instance
    ///         this factory already deployed for the same manifest.
    function deployOrGetRelease(CTMRelease.ReleaseManifest calldata _manifest) external returns (address) {
        bytes32 manifestHash = keccak256(abi.encode(_manifest));
        address existing = deployedFor[manifestHash];
        if (existing != address(0)) {
            return existing;
        }
        CTMRelease release = new CTMRelease();
        release.initialize(_manifest);
        deployedFor[manifestHash] = address(release);
        emit ReleaseDeployed(address(release), manifestHash);
        return address(release);
    }
}

/// @notice Atomic, idempotent deploy-and-initialize factory for {CTMTransition} — see
///         {CTMReleaseFactory} for the model.
contract CTMTransitionFactory {
    /// @notice The instance deployed for each manifest hash (zero = not deployed yet).
    mapping(bytes32 manifestHash => address instance) public deployedFor;

    /// @notice Emitted once a transition has been deployed and initialized atomically.
    event TransitionDeployed(address indexed transition, bytes32 manifestHash);

    /// @notice Deploys + initializes a {CTMTransition} for `_manifest`, or returns the instance
    ///         this factory already deployed for the same manifest.
    function deployOrGetTransition(CTMTransition.TransitionManifest calldata _manifest) external returns (address) {
        bytes32 manifestHash = keccak256(abi.encode(_manifest));
        address existing = deployedFor[manifestHash];
        if (existing != address(0)) {
            return existing;
        }
        CTMTransition transition = new CTMTransition();
        transition.initialize(_manifest);
        deployedFor[manifestHash] = address(transition);
        emit TransitionDeployed(address(transition), manifestHash);
        return address(transition);
    }
}

/// @notice Atomic, idempotent deploy-and-initialize factory for {CoreRegistry} — see
///         {CTMReleaseFactory} for the model.
contract CoreRegistryFactory {
    /// @notice The instance deployed for each manifest hash (zero = not deployed yet).
    mapping(bytes32 manifestHash => address instance) public deployedFor;

    /// @notice Emitted once a core registry has been deployed and initialized atomically.
    event CoreRegistryDeployed(address indexed coreRegistry, bytes32 manifestHash);

    /// @notice Deploys + initializes a {CoreRegistry} for `_manifest`, or returns the instance
    ///         this factory already deployed for the same manifest.
    function deployOrGetCoreRegistry(CoreRegistry.CoreRegistryManifest calldata _manifest) external returns (address) {
        bytes32 manifestHash = keccak256(abi.encode(_manifest));
        address existing = deployedFor[manifestHash];
        if (existing != address(0)) {
            return existing;
        }
        CoreRegistry coreRegistry = new CoreRegistry();
        coreRegistry.initialize(_manifest);
        deployedFor[manifestHash] = address(coreRegistry);
        emit CoreRegistryDeployed(address(coreRegistry), manifestHash);
        return address(coreRegistry);
    }
}
