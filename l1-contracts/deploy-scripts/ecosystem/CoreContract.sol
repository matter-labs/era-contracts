// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

// The canonical definitions of `L2EcosystemContract` and `ZKsyncOSUpgradeType` live in the production
// contracts tree (they key the upgrade registries); they are re-exported here so that all
// deploy-script importers keep working unchanged.
import {L2EcosystemContract, ZKsyncOSUpgradeType} from "contracts/upgrades/registry/ContractIdentifiers.sol";

/// @notice Programming language of a system contract.
enum Language {
    Solidity,
    Yul
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
    SloadContract,
    SystemContractProxyAdmin
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
