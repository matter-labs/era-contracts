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
    // Atomic-interop built-ins, part of `getAdditionalFixedAddressCoreContracts`: the tree's storage is read
    // by the ZKsync OS bootloader.
    L2InteropCommitmentTree,
    AtomicFlowManager
}

/// @notice Fixed-address L2 system contracts implemented in this repository.
/// @dev Their EVM bytecodes come from `l1-contracts/out`; the upgrade path uses a subset behind
/// `SystemContractProxy`.
enum L2SystemContract {
    L2BaseToken,
    L1Messenger,
    SystemContext,
    ContractDeployer,
    // Appended to preserve the ordinals of the existing script-facing enum members.
    L2ComplexUpgrader
}
