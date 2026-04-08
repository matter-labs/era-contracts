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
}
