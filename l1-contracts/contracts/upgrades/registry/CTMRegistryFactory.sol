// SPDX-License-Identifier: MIT

// One deliberately grouped file: the three per-type factories ARE one concept (see the notice
// below for why they cannot be one contract).
// solhint-disable one-contract-per-file

pragma solidity 0.8.28;

import {CTMRelease} from "./CTMRelease.sol";
import {CTMTransition} from "./CTMTransition.sol";
import {CoreRegistry} from "./CoreRegistry.sol";
import {RegistryBootstrapMigration} from "./RegistryBootstrapMigration.sol";

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
///      Instances are deployed via CREATE2 with `salt = keccak256(abi.encode(manifest))`, so the
///      address itself is a commitment to the manifest and is predictable off-chain BEFORE the
///      deployment transaction lands (VM-aware: EVM and EraVM derive CREATE2 addresses
///      differently, and off-chain predictors must use the deploying chain's formula). This is
///      what makes the Gateway bootstrap flow race-free: the predicted address depends only on
///      (factory, manifest, creation code), never on the factory's nonce, so a front-runner
///      cannot displace it. The `deployedFor` mapping is the cheap idempotence check on top.
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
        CTMRelease release = new CTMRelease{salt: manifestHash}();
        // Attest BEFORE initializing: the CREATE2 address is already fixed by the manifest salt, so
        // recording it first is checks-effects-interactions — the attestation is never written after
        // an external call. A revert inside `initialize` reverts the whole transaction, so an
        // uninitialized instance can never stay attested.
        deployedFor[manifestHash] = address(release);
        release.initialize(_manifest);
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
        CTMTransition transition = new CTMTransition{salt: manifestHash}();
        // Attested before initialization; see the note in `deployOrGetRelease`.
        deployedFor[manifestHash] = address(transition);
        transition.initialize(_manifest);
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
        CoreRegistry coreRegistry = new CoreRegistry{salt: manifestHash}();
        // Attested before initialization; see the note in `deployOrGetRelease`.
        deployedFor[manifestHash] = address(coreRegistry);
        coreRegistry.initialize(_manifest);
        emit CoreRegistryDeployed(address(coreRegistry), manifestHash);
        return address(coreRegistry);
    }
}

/// @title RegistryBootstrapMigrationFactory
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Atomic deploy-and-initialize for {RegistryBootstrapMigration}, with the same CREATE2
///         manifest-hash salt the release/transition/core factories use: the address IS the
///         commitment to the migration's pinned starting state and target.
contract RegistryBootstrapMigrationFactory {
    /// @notice The instance deployed for each manifest hash (zero = not deployed yet).
    mapping(bytes32 manifestHash => address instance) public deployedFor;

    /// @notice Emitted once a bootstrap migration has been deployed and initialized atomically.
    event BootstrapMigrationDeployed(address indexed migration, bytes32 manifestHash);

    /// @notice Deploys + initializes a {RegistryBootstrapMigration} for `_manifest`, or returns the
    ///         instance this factory already deployed for the same manifest.
    function deployOrGetMigration(
        RegistryBootstrapMigration.BootstrapManifest calldata _manifest
    ) external returns (address) {
        bytes32 manifestHash = keccak256(abi.encode(_manifest));
        address existing = deployedFor[manifestHash];
        if (existing != address(0)) {
            return existing;
        }
        RegistryBootstrapMigration migration = new RegistryBootstrapMigration{salt: manifestHash}();
        // Attested before initialization; see the note in `deployOrGetRelease`.
        deployedFor[manifestHash] = address(migration);
        migration.initialize(_manifest);
        emit BootstrapMigrationDeployed(address(migration), manifestHash);
        return address(migration);
    }
}
