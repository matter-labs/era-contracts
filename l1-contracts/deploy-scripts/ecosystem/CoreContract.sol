// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @notice Canonical identifier for core L2 contracts that participate in
///         force-deployments and factory-dependency publishing.
///         `CoreOnGatewayHelper.resolve` maps it to the contract and artifact name.
enum CoreContract {
    L2Bridgehub,
    L2AssetRouter,
    L2NativeTokenVault,
    L2MessageRoot,
    UpgradeableBeaconDeployer,
    BaseTokenHolder,
    L2ChainAssetHandler,
    InteropCenter,
    InteropAttributeParser,
    L2InteropHandler,
    L2AssetTracker,
    L2WrappedBaseToken,
    L2MessageVerification,
    L2InteropRootStorage,
    BeaconProxy,
    L2V32Upgrade,
    BridgedStandardERC20,
    DiamondProxy,
    ProxyAdmin,
    TransparentUpgradeableProxy,
    // Atomic-interop built-ins; the bootloader reads the commitment tree's storage.
    L2InteropCommitmentTree,
    AtomicFlowManager
}

/// @notice Fixed-address L2 system contracts upgraded through `SystemContractProxy`.
enum L2SystemContract {
    L2BaseToken,
    L1Messenger,
    SystemContext,
    L2ComplexUpgrader
}
