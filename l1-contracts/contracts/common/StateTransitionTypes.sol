// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

// Shared types for state transition contracts, used by both deploy-scripts and
// Gateway CTM deployer contracts. Canonical single source of truth.

/// @notice Diamond facet contract addresses.
struct Facets {
    /// @notice Address of the Admin facet contract.
    address adminFacet;
    /// @notice Address of the Mailbox facet contract.
    address mailboxFacet;
    /// @notice Address of the Executor facet contract.
    address executorFacet;
    /// @notice Address of the Getters facet contract.
    address gettersFacet;
    /// @notice Address of the Migrator facet contract.
    address migratorFacet;
    /// @notice Address of the Committer facet contract.
    address committerFacet;
    /// @notice Address of the DiamondInit contract.
    address diamondInit;
}

/// @notice Verifier contract addresses.
struct Verifiers {
    /// @notice Address of the VerifierFflonk contract. Left unset by deployment tooling for ZKsync OS.
    address verifierFflonk;
    /// @notice Address of the VerifierPlonk contract.
    address verifierPlonk;
    /// @notice Address of the main Verifier contract.
    address verifier;
}

/// @notice The CTM's proxied contracts, as proxy or implementation addresses.
/// @dev Used as both `proxies` and `implementations` in `StateTransitionDeployedAddresses`. Every proxied contract of a
///      CTM belongs here, including one only some CTMs have: it is left zero for a CTM without it.
struct StateTransitionContracts {
    address chainTypeManager;
    address serverNotifier;
    address validatorTimelock;
    address bytecodesSupplier;
    address permissionlessValidator;
    address interopFeeManager;
}

/// @notice Core Data Availability contract addresses, shared by both
///         deploy-scripts (L1 CTM deployment) and Gateway CTM deployer.
struct DAContracts {
    /// @notice Address of the RollupDAManager contract.
    address rollupDAManager;
    /// @notice Address of the rollup SL DA validator (RelayedSLDAValidator on GW, RollupL1DAValidator on L1).
    address rollupSLDAValidator;
    /// @notice Address of the ValidiumL1DAValidator contract.
    address validiumDAValidator;
}

/// @notice Full set of deployed state transition addresses, shared by both
///         deploy-scripts (L1 CTM deployment) and Gateway CTM deployer.
struct StateTransitionDeployedAddresses {
    StateTransitionContracts proxies;
    StateTransitionContracts implementations;
    Verifiers verifiers;
    Facets facets;
    address genesisUpgrade;
    address chainTypeManagerProxyAdmin;
    /// @notice The bootstrap `CTMRelease` that defines chain genesis.
    address currentRelease;
}
