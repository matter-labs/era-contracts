// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What a version's prepare SETS OUT to change. Declared by the version script
///         (`DefaultCTMUpgrade.upgradeKind`), never inferred from the version numbers the run
///         happens to see. See "Infrastructure-only operations" in
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
enum UpgradeKind {
    // A chain-version edge: the prepare deploys the upgrade engine and the `CTMTransition` chains
    // cross, and the protocol version moves.
    ChainRelease,
    // Ecosystem and CTM-domain singletons behind their proxies, and nothing else: no transition,
    // no upgrade engine, and nothing chain-facing moves.
    InfrastructureOnly
}

/// @notice Parameters for the ecosystem upgrade entry point.
///         Passed as a struct to avoid stack-depth issues as the parameter list grows.
// solhint-disable-next-line gas-struct-packing
struct EcosystemUpgradeParams {
    address bridgehubProxyAddress;
    address ctmProxy;
    address rollupDAManager;
    bytes32 create2FactorySalt;
    string upgradeInputPath;
    string ecosystemOutputPath;
    address governance;
    /// @notice Asset ID of the ZK token used by the InteropCenter for fixed-fee bundles.
    ///         MUST be non-zero — `InteropCenter.initL2` enforces it, and that runs on the genesis path of
    ///         `performForceDeployedContractsInit`, so a zero value breaks the genesis of chains created
    ///         from this release.
    bytes32 zkTokenAssetId;
}

/// @notice Parameters for the standalone core upgrade entry point.
// solhint-disable-next-line gas-struct-packing
struct CoreUpgradeParams {
    address bridgehubProxyAddress;
    bytes32 create2FactorySalt;
    string upgradeInputPath;
    string outputPath;
}

/// @notice Parameters for the standalone CTM upgrade entry point
///         (`DefaultCTMUpgrade.noGovernancePrepare`) when running once per target CTM in a
///         multi-CTM ecosystem.
// solhint-disable-next-line gas-struct-packing
struct CTMUpgradeParams {
    address ctmProxy;
    /// @notice The CTM's rollup `DAManager`, an AdminFacet constructor argument. No CTM- or
    ///         Bridgehub-level getter exposes it — only a live chain's diamond does, and a
    ///         chainless ecosystem has none — so it stays an explicit input rather than something
    ///         the prepare discovers. Contrast the `BytecodesSupplier`, which the prepare reads
    ///         off the CTM's own `L1_BYTECODES_SUPPLIER()` immutable and therefore takes no
    ///         parameter for.
    address rollupDAManager;
    bytes32 create2FactorySalt;
    string upgradeInputPath;
    string outputPath;
    address governance;
    /// @notice Optional v31 core output override. Pre-v31 Bridgehub introspection cannot discover this address.
    address chainRegistrationSender;
    /// @notice Whether the CTM's verifier is the testnet one, which accepts unproven batches.
    ///         Declared per environment in `upgrade-envs/permanent-values/<env>.toml`: true
    ///         everywhere except mainnet.
    bool testnetVerifier;
    /// @notice Asset ID of the ZK token used by the InteropCenter for fixed-fee bundles.
    ///         MUST be non-zero — `InteropCenter.initL2` enforces it, and that runs on the genesis path of
    ///         `performForceDeployedContractsInit`, so a zero value breaks the genesis of chains created
    ///         from this release.
    bytes32 zkTokenAssetId;
    /// @notice The `EcosystemUpgradeExecutor` — the lifecycle coordinator — the core prepare of this
    ///         upgrade deployed or discovered (its output TOML, `[registry].ecosystem_upgrade_executor_addr`).
    ///         The bootstrap's CTM executor is constructed answering to it and every transition's
    ///         timer is bound to it, so the CTM prepare takes it as an input rather than re-deriving
    ///         a deployment it did not make.
    address ecosystemUpgradeExecutor;
    /// @notice The core prepare's `CoreRegistry` (its output TOML,
    ///         `[registry].core_registry_addr`), zero when the upgrade has no ecosystem leg. It is
    ///         the ecosystem leg of the `EcosystemUpgradeOperation` this prepare deploys, and the
    ///         bootstrap edge's second object — the one its derived call sequence covers the
    ///         ecosystem domain from.
    address coreRegistry;
}
