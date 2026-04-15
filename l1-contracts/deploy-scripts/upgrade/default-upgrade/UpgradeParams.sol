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
    ///         Chains upgrading from a pre-v31 version that do not yet have a ZK token on L1
    ///         can pass bytes32(0); fixed-ZK-fee bundles will then fail with ZKTokenNotAvailable
    ///         until a future upgrade sets the asset ID.
    bytes32 zkTokenAssetId;
}
