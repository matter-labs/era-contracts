// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @notice How a built-in contract is deployed in ZKsyncOS upgrades.
/// SystemProxy: deployed via conductContractUpgrade (behind a system proxy).
/// Unsafe: force-deployed directly (no proxy upgrade flow).
enum ZKsyncOSUpgradeType {
    SystemProxy,
    Unsafe
}

/// @notice Canonical identifier for core L2 contracts that participate in
///         force-deployments and factory-dependency publishing.
///         `CoreOnGatewayHelper.resolve` maps it to the ZKsyncOS contract / artifact name.
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
    // Atomic-interop built-ins, part of `getZKsyncOSOnlyContracts`: the commitment tree's storage is read
    // by the ZKsync OS bootloader, and Era chains have no atomic interop.
    L2InteropCommitmentTree,
    AtomicFlowManager
}

/// @notice System contracts that have ZKsyncOS-specific implementations in l1-contracts.
///         These use EVM bytecodes (from l1-contracts/out/) for ZKsyncOS proxy upgrades.
enum ZkSyncOsSystemContract {
    L2BaseToken,
    L1Messenger,
    SystemContext,
    ContractDeployer
}
