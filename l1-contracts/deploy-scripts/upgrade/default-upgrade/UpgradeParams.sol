// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Parameters for the ecosystem upgrade entry point.
///         Passed as a struct to avoid stack-depth issues as the parameter list grows.
// solhint-disable-next-line gas-struct-packing
struct EcosystemUpgradeParams {
    address bridgehubProxyAddress;
    address ctmProxy;
    address bytecodesSupplier;
    address rollupDAManager;
    bool isZKsyncOS;
    bytes32 create2FactorySalt;
    string upgradeInputPath;
    string ecosystemOutputPath;
    address governance;
    /// @notice Asset ID of the ZK token used by the InteropCenter for fixed-fee bundles.
    ///         MUST be non-zero — `InteropCenter.initL2` (called by `_initializeV31Contracts`
    ///         on every chain being upgraded to v31) enforces this, and a zero value would
    ///         revert the L2 upgrade transaction.
    bytes32 zkTokenAssetId;
}

/// @notice Parameters for the standalone core upgrade entry point.
// solhint-disable-next-line gas-struct-packing
struct CoreUpgradeParams {
    address bridgehubProxyAddress;
    bool isZKsyncOS;
    bytes32 create2FactorySalt;
    string upgradeInputPath;
    string outputPath;
}

/// @notice Parameters for the standalone CTM upgrade entry point.
///         Used by `CTMUpgrade_v31.noGovernancePrepare` when running per-CTM in a multi-CTM
///         ecosystem (e.g. ZKsyncOS + EraVM on stage).
// solhint-disable-next-line gas-struct-packing
struct CTMUpgradeParams {
    address ctmProxy;
    address bytecodesSupplier;
    bool isZKsyncOS;
    address rollupDAManager;
    bytes32 create2FactorySalt;
    string upgradeInputPath;
    string outputPath;
    address governance;
    /// @notice Asset ID of the ZK token used by the InteropCenter for fixed-fee bundles.
    ///         MUST be non-zero — `InteropCenter.initL2` (called by `_initializeV31Contracts`
    ///         on every chain being upgraded to v31) enforces this, and a zero value would
    ///         revert the L2 upgrade transaction.
    bytes32 zkTokenAssetId;
}
