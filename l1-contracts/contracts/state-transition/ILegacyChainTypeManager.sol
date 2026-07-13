// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {Diamond} from "./libraries/Diamond.sol";

/// @notice The pre-registry chain-creation parameters. A chain used to be created from a
///         committed diamond cut plus genesis params passed in wholesale; from v32 the CTM reads
///         all of this from its genesis `CTMRegistry` instead (see `IChainTypeManager`).
/// @dev Retained only so the legacy `deploy-scripts/upgrade/default-upgrade` pipeline can still
///      encode `setChainCreationParams` governance calls against pre-v32 CTM deployments. The
///      current `ChainTypeManagerBase` does NOT implement `setChainCreationParams`.
/// @param genesisUpgrade The address used as the diamond cut initialize address on chain creation
/// @param genesisBatchHash Batch hash of the genesis (initial) batch
/// @param genesisIndexRepeatedStorageChanges The serial number of the shortcut storage key for the genesis batch
/// @param genesisBatchCommitment The zk-proof commitment for the genesis batch
/// @param diamondCut The diamond cut for the first upgrade transaction on the newly deployed chain
/// @param forceDeploymentsData The genesis force-deployments descriptor
/// @param registry The CTM registry pinned for chains created at this protocol version
// solhint-disable-next-line gas-struct-packing
struct ChainCreationParams {
    address genesisUpgrade;
    bytes32 genesisBatchHash;
    uint64 genesisIndexRepeatedStorageChanges;
    bytes32 genesisBatchCommitment;
    Diamond.DiamondCutData diamondCut;
    bytes forceDeploymentsData;
    address registry;
}

/// @title Legacy ChainTypeManager surface.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The pre-registry `setChainCreationParams` entrypoint, kept for the legacy
///         `default-upgrade` deploy-script pipeline that targets pre-v32 CTM deployments. The
///         current CTM (`IChainTypeManager`) exposes `setGenesisRegistry` instead.
interface ILegacyChainTypeManager {
    function setChainCreationParams(ChainCreationParams calldata _chainCreationParams) external;
}
