// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IExecutor} from "./IExecutor.sol";
import {IVerifier} from "./IVerifier.sol";
import {DisabledProofSystems, ProofSystem, PubdataContent} from "../../common/Config.sol";

/// @notice The runtime configuration of the followed chain that its batch proofs commit to.
/// @param maxTxGasLimit The effective single-transaction gas limit, as the settlement layer's
/// `getZKsyncOSMaxTxGasLimit()` returns it.
/// @param l1TxFilteringEnabled Whether L1 transaction filtering is enabled.
/// @param largeContractsEnabled Whether large contracts are enabled.
/// @param pubdataContent The pubdata content mode.
struct ZKsyncOSChainConfig {
    uint64 maxTxGasLimit;
    bool l1TxFilteringEnabled;
    bool largeContractsEnabled;
    PubdataContent pubdataContent;
}

/// @notice The parameters a batch mirror is initialized with.
/// @param owner The mirror's owner, also returned as the chain's admin.
/// @param bridgehub The Bridgehub of the chain the mirror is deployed on, where it is registered as the
/// followed chain's ZK chain.
/// @param chainId The followed chain.
/// @param settlementLayerChainId The chain the followed chain settles on.
/// @param chainTypeManager The chain type manager the Bridgehub registers the followed chain under.
/// @param baseTokenAssetId The followed chain's base token asset ID.
/// @param verifier The verifier the followed chain's batches pass on its settlement layer.
/// @param chainConfig The followed chain's runtime configuration at the anchor.
/// @param anchor The followed chain's batch the mirror starts from, as its settlement layer stored it.
struct ZKsyncOSBatchMirrorInitParams {
    address owner;
    address bridgehub;
    uint256 chainId;
    uint256 settlementLayerChainId;
    address chainTypeManager;
    bytes32 baseTokenAssetId;
    IVerifier verifier;
    ZKsyncOSChainConfig chainConfig;
    IExecutor.StoredBatchInfo anchor;
}

/// @title A verify-only copy of a ZKsync OS chain's executed batches, kept on a chain it does not settle on.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {protocol-docs/batch-mirror.md}. The getters and setters it shares with a ZK chain's diamond
/// keep the names and signatures of `IGetters` and `IAdmin`.
interface IZKsyncOSBatchMirror {
    /// @notice Batches `fromBatch`..`toBatch` were mirrored.
    event BatchesMirrored(uint256 indexed fromBatch, uint256 indexed toBatch);

    /// @notice The verifier changed.
    event NewVerifier(address indexed oldVerifier, address indexed newVerifier);

    /// @notice The followed chain's runtime configuration changed.
    event NewZKsyncOSChainConfig(bytes32 indexed oldChainConfigHash, bytes32 indexed newChainConfigHash);

    /// @notice Mirrors the batches of one `proveBatchesSharedBridge` call of the settlement layer.
    /// @dev Callable by validators only. See {protocol-docs/batch-mirror.md#mirroring-a-range}.
    /// @param _commitData The `_commitData` of each `commitBatchesSharedBridge` call that committed the
    /// proved batches, in order, one batch each.
    /// @param _upgradeTxHashes The system upgrade transaction hash each batch was committed with (the
    /// settlement layer's `ReportCommittedBatchProtocolVersion` event), zero for most batches.
    /// @param _proofData The `_proofData` of the `proveBatchesSharedBridge` call.
    function mirrorBatches(
        bytes[] calldata _commitData,
        bytes32[] calldata _upgradeTxHashes,
        bytes calldata _proofData
    ) external;

    /// @notice Adds or removes a validator, the account that mirrors batches.
    /// @param _validator The validator.
    /// @param _active Whether it may mirror batches.
    function setValidator(address _validator, bool _active) external;

    /// @notice Replaces the verifier, following a verifier change of the followed chain.
    /// @param _verifier The new verifier.
    function setVerifier(IVerifier _verifier) external;

    /// @notice Replaces the followed chain's runtime configuration, following a change on its settlement layer.
    /// @param _chainConfig The new configuration.
    function setZKsyncOSChainConfig(ZKsyncOSChainConfig calldata _chainConfig) external;

    /// @notice Enables or disables one proof system, following the followed chain's switch.
    /// @param _proofSystem The proof system; only `ProofSystem.Zisk` is supported.
    /// @param _enabled Whether it is enabled.
    function setProofSystemStatus(ProofSystem _proofSystem, bool _enabled) external;

    /// @notice The followed chain.
    function getChainId() external view returns (uint256);

    /// @notice The chain the followed chain settles on.
    function getSettlementLayerChainId() external view returns (uint256);

    /// @notice The Bridgehub the mirror is registered in.
    function getBridgehub() external view returns (address);

    /// @notice The chain type manager the followed chain is registered under.
    function getChainTypeManager() external view returns (address);

    /// @notice The followed chain's base token asset ID.
    function getBaseTokenAssetId() external view returns (bytes32);

    /// @notice The mirror's owner.
    function getAdmin() external view returns (address);

    /// @notice The verifier.
    function getVerifier() external view returns (address);

    /// @notice The newest mirrored batch; the anchor's number before the first one is mirrored.
    function getTotalBatchesExecuted() external view returns (uint256);

    /// @notice The hash of a mirrored batch's `StoredBatchInfo`, equal to the settlement layer's.
    /// @param _batchNumber The batch.
    function storedBatchHash(uint256 _batchNumber) external view returns (bytes32);

    /// @notice The chain batch root (`l2LogsTreeRoot`) of a mirrored batch.
    /// @param _batchNumber The batch.
    function l2LogsRootHash(uint256 _batchNumber) external view returns (bytes32);

    /// @notice Whether an account may mirror batches.
    /// @param _address The account.
    function isValidator(address _address) external view returns (bool);

    /// @notice The proof systems the followed chain does not require; read by `MultiProofVerifier`.
    function disabledProofSystems() external view returns (DisabledProofSystems memory);

    /// @notice The proof format the verifier accepts under the disabled proof systems.
    function getProofMode() external view returns (uint256);

    /// @notice The followed chain's runtime configuration.
    function getZKsyncOSChainConfig() external view returns (ZKsyncOSChainConfig memory);

    /// @notice The hash of the followed chain's runtime configuration, which every mirrored batch must carry.
    function getZKsyncOSChainConfigHash() external view returns (bytes32);
}
