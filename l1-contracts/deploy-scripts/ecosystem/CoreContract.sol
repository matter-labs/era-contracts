// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @notice Programming language of a system contract.
enum Language {
    Solidity,
    Yul
}

/// @notice Canonical identifier for core L2 contracts that participate in
///         force-deployments and factory-dependency publishing.
///         The enum value is VM-neutral; `CoreOnGatewayHelper.resolve` maps it to
///         the correct Era or ZKsyncOS contract / artifact name.
/// @notice How a built-in contract is deployed in ZKsyncOS upgrades.
/// SystemProxy: deployed via conductContractUpgrade (behind a system proxy).
/// Unsafe: force-deployed directly (no proxy upgrade flow).
enum ZKsyncOSUpgradeType {
    SystemProxy,
    Unsafe
}

/// @notice Identifier for every system contract that lives inside the
///         `system-contracts` folder.  The numeric value encodes the
///         position in the canonical deployment array (index 0..29).
///         Resolver functions in `SystemContractsProcessing` map each
///         entry to its address, Era code-name, language and precompile flag.
enum EraVmSystemContract {
    EmptyContract_0x0000,
    Ecrecover,
    SHA256,
    Identity,
    EcAdd,
    EcMul,
    EcPairing,
    Modexp,
    EmptyContract_0x8001,
    AccountCodeStorage,
    NonceHolder,
    KnownCodesStorage,
    ImmutableSimulator,
    ContractDeployer,
    L1Messenger,
    MsgValueSimulator,
    L2BaseToken,
    SystemContext,
    BootloaderUtilities,
    EventWriter,
    Compressor,
    Keccak256,
    CodeOracle,
    EvmGasManager,
    EvmPredeploysManager,
    EvmHashesStorage,
    P256Verify,
    PubdataChunkPublisher,
    Create2Factory,
    SloadContract
}

enum CoreContract {
    L2Bridgehub,
    L2AssetRouter,
    L2NativeTokenVault,
    L2MessageRoot,
    UpgradeableBeaconDeployer,
    BaseTokenHolder,
    L2ChainAssetHandler,
    InteropCenter,
    InteropHandler,
    L2AssetTracker,
    L2WrappedBaseToken,
    L2MessageVerification,
    L2InteropRootStorage,
    GWAssetTracker,
    BeaconProxy,
    L2V29Upgrade,
    L2V31Upgrade,
    L2SharedBridgeLegacy,
    BridgedStandardERC20,
    DiamondProxy,
    ProxyAdmin
}

/// @notice System contracts that have ZKsyncOS-specific implementations in l1-contracts.
///         Separate from EraVmSystemContract because these need EVM bytecodes (from l1-contracts/out/)
///         for ZKsyncOS proxy upgrades, while EraVmSystemContract entries use ZK bytecodes
///         (from system-contracts/zkout/) for Era force deployments.
enum ZkSyncOsSystemContract {
    L2BaseToken,
    L1Messenger,
    SystemContext,
    ContractDeployer
}
