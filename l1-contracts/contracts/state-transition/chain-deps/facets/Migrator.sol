// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IMigrator} from "../../chain-interfaces/IMigrator.sol";
import {L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS, L2DACommitmentScheme, ZKChainCommitment, CHAIN_MIGRATION_TIME_WINDOW_START_TESTNET, CHAIN_MIGRATION_TIME_WINDOW_START_MAINNET, CHAIN_MIGRATION_TIME_WINDOW_END_TESTNET, CHAIN_MIGRATION_TIME_WINDOW_END_MAINNET, PAUSE_DEPOSITS_TIME_WINDOW_START_TESTNET, PAUSE_DEPOSITS_TIME_WINDOW_START_MAINNET, PAUSE_DEPOSITS_TIME_WINDOW_END_TESTNET, PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET} from "../../../common/Config.sol";
import {PriorityTree} from "../../../state-transition/libraries/PriorityTree.sol";
import {PriorityQueue} from "../../../state-transition/libraries/PriorityQueue.sol";
import {IZKChain} from "../../../state-transition/chain-interfaces/IZKChain.sol";
import {IL1Bridgehub} from "../../../core/bridgehub/IL1Bridgehub.sol";
import {ZKChainBase} from "./ZKChainBase.sol";
import {IChainTypeManager} from "../../IChainTypeManager.sol";
import {IL1ChainAssetHandler} from "../../../core/chain-asset-handler/IL1ChainAssetHandler.sol";
import {AlreadyMigrated, PriorityQueueNotFullyProcessed, TotalPriorityTxsIsZero, ContractNotDeployed, DepositsAlreadyPaused, DepositsNotPaused, ExecutedIsNotConsistentWithVerified, InvalidNumberOfBatchHashes, NotAllBatchesExecuted, NotChainAdmin, NotEraChain, NotHistoricalRoot, NotL1, NotMigrated, OutdatedProtocolVersion, ProtocolVersionNotUpToDate, VerifiedIsNotConsistentWithCommitted, MigrationInProgress} from "../../L1StateTransitionErrors.sol";
import {NotAZKChain, NotCompatibleWithPriorityMode} from "../../../common/L1ContractErrors.sol";
import {OnlyGateway} from "../../../core/bridgehub/L1BridgehubErrors.sol";
import {IL1AssetTracker} from "../../../bridge/asset-tracker/IL1AssetTracker.sol";
import {TxStatus} from "../../../common/Messaging.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZKChainBase} from "../../chain-interfaces/IZKChainBase.sol";

/// @title Migrator Contract handles chain migration between settlement layers.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract MigratorFacet is ZKChainBase, IMigrator {
    using PriorityTree for PriorityTree.Tree;
    using PriorityQueue for PriorityQueue.Queue;

    /// @inheritdoc IZKChainBase
    // solhint-disable-next-line const-name-snakecase
    string public constant override getName = "MigratorFacet";

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 internal immutable L1_CHAIN_ID;

    /// @notice The timestamp when chain migration becomes available.
    uint256 internal immutable CHAIN_MIGRATION_TIME_WINDOW_START;

    /// @notice The timestamp when chain migration is no longer available.
    uint256 internal immutable CHAIN_MIGRATION_TIME_WINDOW_END;

    /// @notice The timestamp when deposits start being paused.
    uint256 internal immutable PAUSE_DEPOSITS_TIME_WINDOW_START;

    /// @notice The timestamp when deposits stop being paused.
    uint256 internal immutable PAUSE_DEPOSITS_TIME_WINDOW_END;

    constructor(uint256 _l1ChainId, bool _isTestnet) {
        L1_CHAIN_ID = _l1ChainId;

        CHAIN_MIGRATION_TIME_WINDOW_START = _isTestnet
            ? CHAIN_MIGRATION_TIME_WINDOW_START_TESTNET
            : CHAIN_MIGRATION_TIME_WINDOW_START_MAINNET;
        CHAIN_MIGRATION_TIME_WINDOW_END = _isTestnet
            ? CHAIN_MIGRATION_TIME_WINDOW_END_TESTNET
            : CHAIN_MIGRATION_TIME_WINDOW_END_MAINNET;
        PAUSE_DEPOSITS_TIME_WINDOW_START = _isTestnet
            ? PAUSE_DEPOSITS_TIME_WINDOW_START_TESTNET
            : PAUSE_DEPOSITS_TIME_WINDOW_START_MAINNET;
        PAUSE_DEPOSITS_TIME_WINDOW_END = _isTestnet
            ? PAUSE_DEPOSITS_TIME_WINDOW_END_TESTNET
            : PAUSE_DEPOSITS_TIME_WINDOW_END_MAINNET;
    }

    modifier onlyL1() {
        _onlyL1();
        _;
    }

    modifier onlyGateway() {
        if (block.chainid == L1_CHAIN_ID) {
            revert OnlyGateway();
        }
        _;
    }

    function _onlyL1() internal view {
        if (block.chainid != L1_CHAIN_ID) {
            revert NotL1(block.chainid);
        }
    }

    /// @inheritdoc IMigrator
    function pauseDepositsBeforeInitiatingMigration() external onlyAdminOrChainTypeManager onlyL1 {
        require(s.pausedDepositsTimestamp + PAUSE_DEPOSITS_TIME_WINDOW_END < block.timestamp, DepositsAlreadyPaused());
        uint256 timestamp;
        // Note, if the chain is new (total number of priority transactions is 0) we allow admin to pause the deposits with immediate effect.
        // This is in place to allow for faster migration for newly spawned chains.
        uint256 totalPriorityTxs = s.priorityTree.getTotalPriorityTxs();
        if (totalPriorityTxs == 0) {
            // We mark the start of pausedDeposits window as current timestamp - PAUSE_DEPOSITS_TIME_WINDOW_START,
            // meaning that starting from this point in time the deposits are immediately paused.
            timestamp = block.timestamp - PAUSE_DEPOSITS_TIME_WINDOW_START;
        } else {
            timestamp = block.timestamp;
        }
        s.pausedDepositsTimestamp = timestamp;
        if (s.settlementLayer != address(0)) {
            require(totalPriorityTxs != 0, TotalPriorityTxsIsZero());
            IL1AssetTracker(s.assetTracker).requestPauseDepositsForChainOnGateway(s.chainId);
        }
        emit DepositsPaused(s.chainId, timestamp);
    }

    /// @inheritdoc IMigrator
    function unpauseDeposits() external onlyAdmin onlyL1 {
        uint256 timestamp = s.pausedDepositsTimestamp;
        bool inPausedWindow = timestamp + PAUSE_DEPOSITS_TIME_WINDOW_START <= block.timestamp &&
            block.timestamp < timestamp + PAUSE_DEPOSITS_TIME_WINDOW_END;
        require(inPausedWindow, DepositsNotPaused());
        require(
            !IL1ChainAssetHandler(IL1Bridgehub(s.bridgehub).chainAssetHandler()).isMigrationInProgress(s.chainId),
            MigrationInProgress()
        );
        _unpauseDeposits();
    }

    function _unpauseDeposits() internal {
        s.pausedDepositsTimestamp = 0;
        emit DepositsUnpaused(s.chainId);
    }

    /// @inheritdoc IMigrator
    function pauseDepositsOnGateway(uint256 _timestamp) external onlyGatewayAssetTracker onlyGateway {
        s.pausedDepositsTimestamp = _timestamp;
        emit DepositsPaused(s.chainId, _timestamp);
    }

    /// @inheritdoc IMigrator
    // slither-disable-next-line locked-ether
    function forwardedBridgeBurn(
        address _settlementLayer,
        address _originalCaller,
        bytes calldata _data
    ) external payable override onlyChainAssetHandler returns (bytes memory chainBridgeMintData) {
        if (s.priorityModeInfo.canBeActivated) {
            revert NotCompatibleWithPriorityMode();
        }
        if (s.settlementLayer != address(0)) {
            revert AlreadyMigrated();
        }
        if (_originalCaller != s.admin) {
            revert NotChainAdmin(_originalCaller, s.admin);
        }

        /// We require that all the priority transactions are processed.
        require(s.priorityTree.getSize() == 0, PriorityQueueNotFullyProcessed());

        uint256 timestamp = s.pausedDepositsTimestamp;
        require(
            timestamp + CHAIN_MIGRATION_TIME_WINDOW_START < block.timestamp &&
                block.timestamp < timestamp + CHAIN_MIGRATION_TIME_WINDOW_END,
            DepositsNotPaused()
        );

        // We want to trust interop messages coming from Era chains which implies they can use only trusted settlement layers,
        // ie, controlled by the governance, which is currently Era Gateways and Ethereum.
        // Otherwise a malicious settlement layer could forge an interop message from an Era chain.
        if (_settlementLayer != L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS) {
            uint256 chainId = IZKChain(_settlementLayer).getChainId();
            if (_settlementLayer != IL1Bridgehub(s.bridgehub).getZKChain(chainId)) {
                revert NotAZKChain(_settlementLayer);
            }
            if (s.chainTypeManager != IL1Bridgehub(s.bridgehub).chainTypeManager(chainId)) {
                revert NotEraChain();
            }
        }

        // As of now all we need in this function is the chainId so we encode it and pass it down in the _chainData field
        uint256 protocolVersion = abi.decode(_data, (uint256));

        uint256 currentProtocolVersion = s.protocolVersion;

        if (currentProtocolVersion != protocolVersion) {
            revert ProtocolVersionNotUpToDate(currentProtocolVersion, protocolVersion);
        }

        // We require all committed batches to be executed, since each batch has a predefined settlement layer.
        // Also we assume that GW -> L1 transactions can never fail and provide no recovery mechanism from it.
        // That's why we need to bound the gas that can be consumed during a GW->L1 migration.
        if (s.totalBatchesCommitted != s.totalBatchesExecuted) {
            revert NotAllBatchesExecuted();
        }

        s.settlementLayer = _settlementLayer;
        chainBridgeMintData = abi.encode(prepareChainCommitment());
    }

    /// @inheritdoc IMigrator
    // slither-disable-next-line locked-ether
    function forwardedBridgeMint(
        bytes calldata _data,
        bool _contractAlreadyDeployed
    ) external payable override onlyChainAssetHandler {
        ZKChainCommitment memory _commitment = abi.decode(_data, (ZKChainCommitment));

        IChainTypeManager ctm = IChainTypeManager(s.chainTypeManager);

        uint256 currentProtocolVersion = s.protocolVersion;
        uint256 protocolVersion = ctm.protocolVersion();
        if (currentProtocolVersion != protocolVersion) {
            revert OutdatedProtocolVersion(protocolVersion, currentProtocolVersion);
        }
        uint256 batchesExecuted = _commitment.totalBatchesExecuted;
        uint256 batchesVerified = _commitment.totalBatchesVerified;
        uint256 batchesCommitted = _commitment.totalBatchesCommitted;

        s.totalBatchesCommitted = batchesCommitted;
        s.totalBatchesVerified = batchesVerified;
        s.totalBatchesExecuted = batchesExecuted;
        s.isPermanentRollup = _commitment.isPermanentRollup;
        s.precommitmentForTheLatestBatch = _commitment.precommitmentForTheLatestBatch;

        // Some consistency checks just in case.
        if (batchesExecuted > batchesVerified) {
            revert ExecutedIsNotConsistentWithVerified(batchesExecuted, batchesVerified);
        }
        if (batchesVerified > batchesCommitted) {
            revert VerifiedIsNotConsistentWithCommitted(batchesVerified, batchesCommitted);
        }

        // In the worst case, we may need to revert all the committed batches that were not executed.
        // This means that the stored batch hashes should be stored for [batchesExecuted; batchesCommitted] batches, i.e.
        // there should be batchesCommitted - batchesExecuted + 1 hashes.
        if (_commitment.batchHashes.length != batchesCommitted - batchesExecuted + 1) {
            revert InvalidNumberOfBatchHashes(_commitment.batchHashes.length, batchesCommitted - batchesExecuted + 1);
        }

        // Note that this part is done in O(N), i.e. it is the responsibility of the admin of the chain to ensure that the total number of
        // outstanding committed batches is not too long.
        uint256 length = _commitment.batchHashes.length;
        for (uint256 i = 0; i < length; ++i) {
            s.storedBatchHashes[batchesExecuted + i] = _commitment.batchHashes[i];
        }

        if (block.chainid == L1_CHAIN_ID) {
            // L1 PTree contains all L1->L2 transactions.
            if (
                !s.priorityTree.isHistoricalRoot(
                    _commitment.priorityTree.sides[_commitment.priorityTree.sides.length - 1]
                )
            ) {
                revert NotHistoricalRoot(_commitment.priorityTree.sides[_commitment.priorityTree.sides.length - 1]);
            }
            if (!_contractAlreadyDeployed) {
                revert ContractNotDeployed();
            }
            if (s.settlementLayer == address(0)) {
                revert NotMigrated();
            }
            s.priorityTree.l1Reinit(_commitment.priorityTree);
        } else if (_contractAlreadyDeployed) {
            if (s.settlementLayer == address(0)) {
                revert NotMigrated();
            }
            s.priorityTree.checkGWReinit(_commitment.priorityTree);
            s.priorityTree.initFromCommitment(_commitment.priorityTree);
        } else {
            s.priorityTree.initFromCommitment(_commitment.priorityTree);
        }
        _forceDeactivateQueue();

        s.l2SystemContractsUpgradeTxHash = _commitment.l2SystemContractsUpgradeTxHash;
        s.l2SystemContractsUpgradeBatchNumber = _commitment.l2SystemContractsUpgradeBatchNumber;

        // Set the settlement to 0 - as this is the current settlement chain.
        s.settlementLayer = address(0);

        _setDAValidatorPair(address(0), L2DACommitmentScheme.NONE);
        _unpauseDeposits();

        emit MigrationComplete();
    }

    /// @inheritdoc IMigrator
    // slither-disable-next-line locked-ether
    function forwardedBridgeConfirmTransferResult(
        uint256 /* _chainId */,
        TxStatus _txStatus,
        bytes32 /* _assetInfo */,
        address /* _depositSender */,
        bytes calldata _chainData
    ) external payable override onlyChainAssetHandler {
        _unpauseDeposits();

        if (_txStatus == TxStatus.Success) {
            return;
        }
        // As of now all we need in this function is the chainId so we encode it and pass it down in the _chainData field
        uint256 protocolVersion = abi.decode(_chainData, (uint256));

        if (s.settlementLayer == address(0)) {
            revert NotMigrated();
        }
        uint256 currentProtocolVersion = s.protocolVersion;
        if (currentProtocolVersion != protocolVersion) {
            revert OutdatedProtocolVersion(protocolVersion, currentProtocolVersion);
        }

        s.settlementLayer = address(0);
    }

    /// @inheritdoc IMigrator
    /// @notice Returns the commitment for a chain.
    /// @dev Note, that this is a getter method helpful for debugging and should not be relied upon by clients.
    /// @return commitment The commitment for the chain.
    function prepareChainCommitment() public view returns (ZKChainCommitment memory commitment) {
        commitment.totalBatchesCommitted = s.totalBatchesCommitted;
        commitment.totalBatchesVerified = s.totalBatchesVerified;
        commitment.totalBatchesExecuted = s.totalBatchesExecuted;
        commitment.l2SystemContractsUpgradeBatchNumber = s.l2SystemContractsUpgradeBatchNumber;
        commitment.l2SystemContractsUpgradeTxHash = s.l2SystemContractsUpgradeTxHash;
        commitment.priorityTree = s.priorityTree.getCommitment();
        commitment.isPermanentRollup = s.isPermanentRollup;
        commitment.precommitmentForTheLatestBatch = s.precommitmentForTheLatestBatch;

        // just in case
        if (commitment.totalBatchesExecuted > commitment.totalBatchesVerified) {
            revert ExecutedIsNotConsistentWithVerified(
                commitment.totalBatchesExecuted,
                commitment.totalBatchesVerified
            );
        }
        if (commitment.totalBatchesVerified > commitment.totalBatchesCommitted) {
            revert VerifiedIsNotConsistentWithCommitted(
                commitment.totalBatchesVerified,
                commitment.totalBatchesCommitted
            );
        }

        uint256 blocksToRemember = commitment.totalBatchesCommitted - commitment.totalBatchesExecuted + 1;

        bytes32[] memory batchHashes = new bytes32[](blocksToRemember);

        for (uint256 i = 0; i < blocksToRemember; ++i) {
            unchecked {
                batchHashes[i] = s.storedBatchHashes[commitment.totalBatchesExecuted + i];
            }
        }

        commitment.batchHashes = batchHashes;
    }
}
