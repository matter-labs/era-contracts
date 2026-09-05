// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev No VM-flavor field: this release only accepts ZKsync OS CTMs. The version-scoped v31
///      preparation flow verifies the source CTM onchain, so a caller-supplied flag could only
///      restate or contradict that check.
/// @notice Parameters for the ecosystem upgrade entry point.
///         Passed as a struct to avoid stack-depth issues as the parameter list grows.
// solhint-disable-next-line gas-struct-packing
struct EcosystemUpgradeParams {
    address bridgehubProxyAddress;
    address ctmProxy;
    address bytecodesSupplier;
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

/// @notice Parameters for the standalone CTM upgrade entry point.
///         Used by `CTMUpgrade_v31.noGovernancePrepare` when running once per target CTM.
// solhint-disable-next-line gas-struct-packing
struct CTMUpgradeParams {
    address ctmProxy;
    address bytecodesSupplier;
    address rollupDAManager;
    bytes32 create2FactorySalt;
    string upgradeInputPath;
    string outputPath;
    address governance;
    /// @notice Optional v31 core output override. Pre-v31 Bridgehub introspection cannot discover this address.
    address chainRegistrationSender;
    /// @notice Asset ID of the ZK token used by the InteropCenter for fixed-fee bundles.
    ///         MUST be non-zero — `InteropCenter.initL2` enforces it, and that runs on the genesis path of
    ///         `performForceDeployedContractsInit`, so a zero value breaks the genesis of chains created
    ///         from this release.
    bytes32 zkTokenAssetId;
}
