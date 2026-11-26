// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {
    IZKsyncOSBatchMirror,
    ZKsyncOSBatchMirrorInitParams,
    ZKsyncOSChainConfig
} from "../chain-interfaces/IZKsyncOSBatchMirror.sol";
import {IAdmin} from "../chain-interfaces/IAdmin.sol";
import {IExecutor} from "../chain-interfaces/IExecutor.sol";
import {IVerifier} from "../chain-interfaces/IVerifier.sol";
import {IZKsyncOSVerifier} from "../chain-interfaces/IZKsyncOSVerifier.sol";
import {CommitBatchInfoZKsyncOS} from "../chain-interfaces/ICommitter.sol";
import {BatchDecoder} from "../libraries/BatchDecoder.sol";
import {ZKsyncOSBatchCommitment} from "../libraries/ZKsyncOSBatchCommitment.sol";
import {StoredBatchHashing} from "../chain-deps/StoredBatchHashing.sol";
import {IBridgehubBase} from "../../core/bridgehub/IBridgehubBase.sol";
import {IMessageRootBase} from "../../core/message-root/IMessageRoot.sol";
import {DisabledProofSystems, ProofSystem} from "../../common/Config.sol";
import {
    BatchHashMismatch,
    CanOnlyProcessOneBatch,
    ChainConfigHashMismatch,
    EmptyData,
    IncorrectBatchChainId,
    InvalidProof,
    InvalidProofSystem,
    Unauthorized,
    ZeroAddress
} from "../../common/L1ContractErrors.sol";
import {
    BatchMirrorLengthMismatch,
    SettlementLayerChainIdMismatch,
    UnexpectedUpgradeTxHash
} from "../L1StateTransitionErrors.sol";

/// @title A verify-only copy of a ZKsync OS chain's executed batches, kept on a chain it does not settle on.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {protocol-docs/batch-mirror.md}.
/// @dev Deployed behind a proxy: the Bridgehub registers the followed chain under this address for good.
/// The owner and the proxy admin are trusted for soundness: either can make the mirror accept any batch root,
/// and with it any message of the followed chain. So are the validators, which can mirror any batch that
/// has a valid proof, including one the settlement layer would refuse to execute.
/// See {protocol-docs/batch-mirror.md#what-the-mirror-trusts}.
contract ZKsyncOSBatchMirror is IZKsyncOSBatchMirror, Ownable2StepUpgradeable {
    /// @dev The followed chain.
    uint256 internal chainId;

    /// @dev The chain the followed chain settles on.
    uint256 internal settlementLayerChainId;

    /// @dev The Bridgehub the mirror is registered in.
    address internal bridgehub;

    /// @dev The chain type manager the followed chain is registered under.
    address internal chainTypeManager;

    /// @dev The followed chain's base token asset ID.
    bytes32 internal baseTokenAssetId;

    /// @dev The verifier the followed chain's batches pass on its settlement layer.
    IVerifier internal verifier;

    /// @dev The followed chain's runtime configuration.
    ZKsyncOSChainConfig internal chainConfig;

    /// @dev The `ProofSystem` bitmask of the proof systems the followed chain does not require.
    uint8 internal disabledProofSystemsMask;

    /// @dev The accounts that may mirror batches.
    mapping(address validator => bool active) internal validators;

    /// @dev The newest mirrored batch.
    uint256 internal totalBatchesExecuted;

    /// @dev The hash of each mirrored batch's `StoredBatchInfo`.
    mapping(uint256 batchNumber => bytes32 batchHash) internal storedBatchHashes;

    /// @dev The chain batch root of each mirrored batch.
    mapping(uint256 batchNumber => bytes32 root) internal l2LogsRootHashes;

    /// @dev The system upgrade transaction the owner expects in a coming batch, as the settlement layer's
    /// `l2SystemContractsUpgradeTxHash`; zero when none is expected.
    bytes32 internal l2SystemContractsUpgradeTxHash;

    modifier onlyValidator() {
        if (!validators[msg.sender]) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the mirror at a batch of the followed chain that its settlement layer stored.
    /// @param _params The initialization parameters.
    function initialize(ZKsyncOSBatchMirrorInitParams calldata _params) external initializer {
        if (
            _params.owner == address(0) ||
            _params.bridgehub == address(0) ||
            _params.chainTypeManager == address(0) ||
            address(_params.verifier) == address(0)
        ) {
            revert ZeroAddress();
        }
        _transferOwnership(_params.owner);
        chainId = _params.chainId;
        settlementLayerChainId = _params.settlementLayerChainId;
        bridgehub = _params.bridgehub;
        chainTypeManager = _params.chainTypeManager;
        baseTokenAssetId = _params.baseTokenAssetId;
        _setVerifier(_params.verifier);
        _setZKsyncOSChainConfig(_params.chainConfig);

        uint256 anchorBatchNumber = _params.anchor.batchNumber;
        totalBatchesExecuted = anchorBatchNumber;
        storedBatchHashes[anchorBatchNumber] = StoredBatchHashing.hashStoredBatchInfo(_params.anchor);
        l2LogsRootHashes[anchorBatchNumber] = _params.anchor.l2LogsTreeRoot;
    }

    /*//////////////////////////////////////////////////////////////
                            MIRRORING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IZKsyncOSBatchMirror
    function mirrorBatches(
        bytes[] calldata _commitData,
        bytes32[] calldata _upgradeTxHashes,
        bytes calldata _proofData
    ) external onlyValidator {
        uint256 batchesCount = _commitData.length;
        if (batchesCount == 0) {
            revert EmptyData();
        }
        if (_upgradeTxHashes.length != batchesCount) {
            revert BatchMirrorLengthMismatch(batchesCount, _upgradeTxHashes.length);
        }
        _consumeUpgradeTxHash(_upgradeTxHashes);
        uint256 lastMirrored = totalBatchesExecuted;
        (
            IExecutor.StoredBatchInfo memory previousBatch,
            IExecutor.StoredBatchInfo[] memory provedBatches,
            uint256[] memory proof
        ) = BatchDecoder.decodeAndCheckProofData(_proofData, lastMirrored + 1, lastMirrored + batchesCount);
        if (provedBatches.length != batchesCount) {
            revert BatchMirrorLengthMismatch(batchesCount, provedBatches.length);
        }
        _checkStoredBatchHash(storedBatchHashes[lastMirrored], previousBatch);
        uint256[] memory proofPublicInput = _commitBatches(previousBatch, provedBatches, _commitData, _upgradeTxHashes);

        // The verifier is called by the mirror, so `MultiProofVerifier` reads this contract's `disabledProofSystems`.
        if (!verifier.verify(proofPublicInput, proof)) {
            revert InvalidProof();
        }

        _executeBatches(provedBatches);
        emit BatchesMirrored(lastMirrored + 1, lastMirrored + batchesCount);
    }

    /// @dev Requires every non-zero upgrade transaction hash to be the one the owner expects and clears it,
    /// as the settlement layer's `CommitterFacet` uses `l2SystemContractsUpgradeTxHash` for one batch only.
    function _consumeUpgradeTxHash(bytes32[] calldata _upgradeTxHashes) internal {
        bytes32 expected = l2SystemContractsUpgradeTxHash;
        uint256 batchesCount = _upgradeTxHashes.length;
        for (uint256 i = 0; i < batchesCount; ++i) {
            bytes32 upgradeTxHash = _upgradeTxHashes[i];
            if (upgradeTxHash == bytes32(0)) {
                continue;
            }
            if (upgradeTxHash != expected) {
                revert UnexpectedUpgradeTxHash(expected, upgradeTxHash);
            }
            // A second batch with the same upgrade transaction fails the check above.
            expected = bytes32(0);
            delete l2SystemContractsUpgradeTxHash;
        }
    }

    /// @dev Recomputes the batches of the commits, checks that they are the proved ones and returns the
    /// proof's public input.
    function _commitBatches(
        IExecutor.StoredBatchInfo memory _previousBatch,
        IExecutor.StoredBatchInfo[] memory _provedBatches,
        bytes[] calldata _commitData,
        bytes32[] calldata _upgradeTxHashes
    ) internal view returns (uint256[] memory proofPublicInput) {
        bytes32 expectedChainConfigHash = getZKsyncOSChainConfigHash();
        uint256 batchesCount = _provedBatches.length;
        proofPublicInput = new uint256[](batchesCount);
        for (uint256 i = 0; i < batchesCount; ++i) {
            _previousBatch = _commitOneBatch(
                _previousBatch,
                _commitData[i],
                _upgradeTxHashes[i],
                expectedChainConfigHash
            );
            _checkStoredBatchHash(StoredBatchHashing.hashStoredBatchInfo(_previousBatch), _provedBatches[i]);
            proofPublicInput[i] = uint256(_previousBatch.commitment);
        }
    }

    /// @dev Recomputes the `StoredBatchInfo` the settlement layer's `CommitterFacet` stored for one
    /// commit, after the checks of `_commitOneBatch` that do not depend on the settlement layer's state.
    function _commitOneBatch(
        IExecutor.StoredBatchInfo memory _previousBatch,
        bytes calldata _commitData,
        bytes32 _upgradeTxHash,
        bytes32 _expectedChainConfigHash
    ) internal view returns (IExecutor.StoredBatchInfo memory) {
        uint256 batchNumber = uint256(_previousBatch.batchNumber) + 1;
        (
            IExecutor.StoredBatchInfo memory lastCommittedBatchData,
            CommitBatchInfoZKsyncOS[] memory newBatchesData
        ) = BatchDecoder.decodeAndCheckCommitData(_commitData, batchNumber, batchNumber);
        if (newBatchesData.length != 1) {
            revert CanOnlyProcessOneBatch();
        }
        _checkStoredBatchHash(StoredBatchHashing.hashStoredBatchInfo(_previousBatch), lastCommittedBatchData);

        CommitBatchInfoZKsyncOS memory newBatch = newBatchesData[0];
        if (newBatch.chainId != chainId) {
            revert IncorrectBatchChainId(newBatch.chainId, chainId);
        }
        if (newBatch.slChainId != settlementLayerChainId) {
            revert SettlementLayerChainIdMismatch();
        }
        if (newBatch.chainConfigHash != _expectedChainConfigHash) {
            revert ChainConfigHashMismatch(_expectedChainConfigHash, newBatch.chainConfigHash);
        }
        return ZKsyncOSBatchCommitment.storedBatchInfo(_previousBatch.batchHash, newBatch, _upgradeTxHash);
    }

    /// @dev Stores the proved batches and appends their chain batch roots to the MessageRoot, as the
    /// settlement layer's `ExecutorFacet` does when it executes them.
    function _executeBatches(IExecutor.StoredBatchInfo[] memory _batches) internal {
        IMessageRootBase messageRoot = IBridgehubBase(bridgehub).messageRoot();
        uint256 batchesCount = _batches.length;
        for (uint256 i = 0; i < batchesCount; ++i) {
            IExecutor.StoredBatchInfo memory batch = _batches[i];
            storedBatchHashes[batch.batchNumber] = StoredBatchHashing.hashStoredBatchInfo(batch);
            l2LogsRootHashes[batch.batchNumber] = batch.l2LogsTreeRoot;
            messageRoot.addChainBatchRootV32(chainId, batch.batchNumber, batch.l2LogsTreeRoot);
            emit IExecutor.BlockExecution(batch.batchNumber, batch.batchHash, batch.commitment);
        }
        totalBatchesExecuted += batchesCount;
    }

    function _checkStoredBatchHash(bytes32 _expected, IExecutor.StoredBatchInfo memory _batch) internal pure {
        bytes32 actual = StoredBatchHashing.hashStoredBatchInfo(_batch);
        if (actual != _expected) {
            revert BatchHashMismatch(_expected, actual);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IZKsyncOSBatchMirror
    function setValidator(address _validator, bool _active) external onlyOwner {
        validators[_validator] = _active;
        emit IAdmin.ValidatorStatusUpdate(_validator, _active);
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function setVerifier(IVerifier _verifier) external onlyOwner {
        if (address(_verifier) == address(0)) {
            revert ZeroAddress();
        }
        _setVerifier(_verifier);
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function setZKsyncOSChainConfig(ZKsyncOSChainConfig calldata _chainConfig) external onlyOwner {
        _setZKsyncOSChainConfig(_chainConfig);
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function setSettlementLayerChainId(uint256 _settlementLayerChainId) external onlyOwner {
        emit NewSettlementLayerChainId(settlementLayerChainId, _settlementLayerChainId);
        settlementLayerChainId = _settlementLayerChainId;
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function setL2SystemContractsUpgradeTxHash(bytes32 _upgradeTxHash) external onlyOwner {
        emit NewL2SystemContractsUpgradeTxHash(l2SystemContractsUpgradeTxHash, _upgradeTxHash);
        l2SystemContractsUpgradeTxHash = _upgradeTxHash;
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function setProofSystemStatus(ProofSystem _proofSystem, bool _enabled) external onlyOwner {
        // The same switch as `AdminFacet.setProofSystemStatus`: only ZiSK can be turned off on ZKsync OS.
        if (_proofSystem != ProofSystem.Zisk) {
            revert InvalidProofSystem(uint8(_proofSystem));
        }
        uint8 proofSystemMask = uint8(1 << uint8(_proofSystem));
        uint8 oldDisabledProofSystems = disabledProofSystemsMask;
        uint8 newDisabledProofSystems = _enabled
            ? oldDisabledProofSystems & ~proofSystemMask
            : oldDisabledProofSystems | proofSystemMask;
        disabledProofSystemsMask = newDisabledProofSystems;
        emit IAdmin.NewDisabledProofSystems(oldDisabledProofSystems, newDisabledProofSystems);
    }

    function _setVerifier(IVerifier _verifier) internal {
        emit NewVerifier(address(verifier), address(_verifier));
        verifier = _verifier;
    }

    function _setZKsyncOSChainConfig(ZKsyncOSChainConfig memory _chainConfig) internal {
        bytes32 oldChainConfigHash = getZKsyncOSChainConfigHash();
        chainConfig = _chainConfig;
        emit NewZKsyncOSChainConfig(oldChainConfigHash, getZKsyncOSChainConfigHash());
    }

    /*//////////////////////////////////////////////////////////////
                            GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IZKsyncOSBatchMirror
    function getChainId() external view returns (uint256) {
        return chainId;
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function getSettlementLayerChainId() external view returns (uint256) {
        return settlementLayerChainId;
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function getBridgehub() external view returns (address) {
        return bridgehub;
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function getChainTypeManager() external view returns (address) {
        return chainTypeManager;
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function getBaseTokenAssetId() external view returns (bytes32) {
        return baseTokenAssetId;
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function getAdmin() external view returns (address) {
        return owner();
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function getVerifier() external view returns (address) {
        return address(verifier);
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function getTotalBatchesExecuted() external view returns (uint256) {
        return totalBatchesExecuted;
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function getL2SystemContractsUpgradeTxHash() external view returns (bytes32) {
        return l2SystemContractsUpgradeTxHash;
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function storedBatchHash(uint256 _batchNumber) external view returns (bytes32) {
        return storedBatchHashes[_batchNumber];
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function l2LogsRootHash(uint256 _batchNumber) external view returns (bytes32) {
        return l2LogsRootHashes[_batchNumber];
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function isValidator(address _address) external view returns (bool) {
        return validators[_address];
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function disabledProofSystems() external view returns (DisabledProofSystems memory) {
        uint8 mask = disabledProofSystemsMask;
        return
            DisabledProofSystems({
                boojum: mask & uint8(1 << uint8(ProofSystem.Boojum)) != 0,
                airbender: mask & uint8(1 << uint8(ProofSystem.Airbender)) != 0,
                zisk: mask & uint8(1 << uint8(ProofSystem.Zisk)) != 0
            });
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function getProofMode() external view returns (uint256) {
        return IZKsyncOSVerifier(address(verifier)).getProofMode(disabledProofSystemsMask);
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function getZKsyncOSChainConfig() external view returns (ZKsyncOSChainConfig memory) {
        return chainConfig;
    }

    /// @inheritdoc IZKsyncOSBatchMirror
    function getZKsyncOSChainConfigHash() public view returns (bytes32) {
        ZKsyncOSChainConfig memory config = chainConfig;
        return
            ZKsyncOSBatchCommitment.chainConfigHash({
                _chainId: chainId,
                _maxTxGasLimit: config.maxTxGasLimit,
                _pubdataContent: config.pubdataContent,
                _l1TxFilteringEnabled: config.l1TxFilteringEnabled,
                _largeContractsEnabled: config.largeContractsEnabled
            });
    }
}
