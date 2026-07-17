// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMRelease} from "./CTMRelease.sol";
import {CTMTransition} from "./CTMTransition.sol";
import {CoreRegistry} from "./CoreRegistry.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Factories that deploy and initialize a write-once registry object ({CTMRelease} /
///         {CTMTransition} / {CoreRegistry}) in a SINGLE transaction.
///
/// @dev These registries have an unauthenticated, one-shot `initialize`. Deploying them as two
///      separate transactions (`new X()` then `X.initialize(...)`) opens a first-caller-wins
///      window: anyone can front-run `initialize` with a different manifest, burning the deployed
///      address (the deploy script would then revert on its manifest-hash post-check, but the
///      address is lost). Deploying through a factory performs the deploy and the initialize
///      within one transaction, so the returned instance is already initialized and no
///      uninitialized, front-runnable window ever exists on-chain. The factories are stateless,
///      so they need no initialization of their own.
/// @dev One factory per registry type — NOT one combined factory: a factory's runtime code
///      embeds the creation bytecode of the contract it deploys, and all three together exceed
///      the EIP-170 runtime size limit.
contract CTMReleaseFactory {
    /// @notice Emitted once a release has been deployed and initialized atomically.
    event ReleaseDeployed(address indexed release, bytes32 manifestHash);

    /// @notice Atomically deploys and initializes a {CTMRelease}.
    function deployRelease(CTMRelease.ReleaseManifest calldata _manifest) external returns (address) {
        CTMRelease release = new CTMRelease();
        release.initialize(_manifest);
        emit ReleaseDeployed(address(release), release.manifestHash());
        return address(release);
    }
}

/// @notice Atomic deploy-and-initialize factory for {CTMTransition} — see {CTMReleaseFactory}.
contract CTMTransitionFactory {
    /// @notice Emitted once a transition has been deployed and initialized atomically.
    event TransitionDeployed(address indexed transition, bytes32 manifestHash);

    /// @notice Atomically deploys and initializes a {CTMTransition}.
    function deployTransition(CTMTransition.TransitionManifest calldata _manifest) external returns (address) {
        CTMTransition transition = new CTMTransition();
        transition.initialize(_manifest);
        emit TransitionDeployed(address(transition), transition.manifestHash());
        return address(transition);
    }
}

/// @notice Atomic deploy-and-initialize factory for {CoreRegistry} — see {CTMReleaseFactory}.
contract CoreRegistryFactory {
    /// @notice Emitted once a core registry has been deployed and initialized atomically.
    event CoreRegistryDeployed(address indexed coreRegistry, bytes32 manifestHash);

    /// @notice Atomically deploys and initializes a {CoreRegistry}.
    function deployCoreRegistry(CoreRegistry.CoreRegistryManifest calldata _manifest) external returns (address) {
        CoreRegistry coreRegistry = new CoreRegistry();
        coreRegistry.initialize(_manifest);
        emit CoreRegistryDeployed(address(coreRegistry), coreRegistry.manifestHash());
        return address(coreRegistry);
    }
}
