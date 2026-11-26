// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {FeeParams, PriorityModeInformation, PubdataPricingMode, ZKChainStorage} from "../ZKChainStorage.sol";
import {ReentrancyGuard} from "../../../common/ReentrancyGuard.sol";
import {PriorityQueue} from "../../libraries/PriorityQueue.sol";
import {PriorityTree} from "../../libraries/PriorityTree.sol";
import {L1DAValidatorAddressIsZero, NotSettlementLayer} from "../../L1StateTransitionErrors.sol";
import {
    BatchHashMismatch,
    BaseTokenGasPriceDenominatorNotSet,
    InvalidDAForPermanentRollup,
    InvalidL2DACommitmentScheme,
    NotCompatibleWithPriorityMode,
    PubdataContentLockedForPermanentRollup,
    Unauthorized,
    OnlyNormalMode,
    OnlyPriorityMode,
    ZKsyncOSChainConfigUpdateWithUnverifiedBatches,
    ZKsyncOSMaxTxGasLimitTooHigh,
    ZKsyncOSMaxTxGasLimitTooLow
} from "../../../common/L1ContractErrors.sol";
import {L2_CHAIN_ASSET_HANDLER_ADDR, L2_INTEROP_CENTER_ADDR} from "../../../common/l2-helpers/L2ContractAddresses.sol";
import {IL1Bridgehub} from "../../../core/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "../../../core/bridgehub/IBridgehubBase.sol";
import {Math} from "@openzeppelin/contracts-v4/utils/math/Math.sol";
import {
    L1_GAS_PER_PUBDATA_BYTE,
    ZKSYNC_OS_PRIORITY_OPERATION_L2_TX_TYPE,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE,
    ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT,
    ZKSYNC_OS_FRI_PROOF_VERIFICATION_DISABLED,
    ZKSYNC_OS_MAX_BLOCK_GAS_LIMIT,
    L2DACommitmentScheme,
    PubdataContent
} from "../../../common/Config.sol";
import {CantRevertExecutedBatch, RevertedBatchNotAfterNewLastBatch} from "../../../common/L1ContractErrors.sol";
import {IAdmin} from "../../chain-interfaces/IAdmin.sol";
import {IZKsyncOSVerifier} from "../../chain-interfaces/IZKsyncOSVerifier.sol";
import {IExecutor} from "../../chain-interfaces/IExecutor.sol";
import {StoredBatchHashing} from "../StoredBatchHashing.sol";
import {RollupDAManager} from "../../data-availability/RollupDAManager.sol";

/// @title Base contract containing functions accessible to the other facets.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract ZKChainBase is ReentrancyGuard {
    using PriorityQueue for PriorityQueue.Queue;
    using PriorityTree for PriorityTree.Tree;

    // slither-disable-next-line uninitialized-state
    ZKChainStorage internal s;

    /// @notice Checks that the message sender is an active admin
    modifier onlyAdmin() {
        if (msg.sender != s.admin) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Checks if validator is active
    modifier onlyValidator() {
        if (!s.validators[msg.sender]) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Ensures Priority Mode is not active.
    modifier notPriorityMode() {
        require(!s.priorityModeInfo.activated, OnlyNormalMode());
        _;
    }

    /// @notice Ensures Priority Mode is active.
    modifier onlyPriorityMode() {
        require(s.priorityModeInfo.activated, OnlyPriorityMode());
        _;
    }

    /// @notice Allows whitelisted validators, or the `PermissionlessValidator` when Priority Mode is active.
    /// @dev Reverts with {Unauthorized} if `msg.sender` is not authorized for the current mode.
    modifier onlyValidatorOrPriorityMode() {
        PriorityModeInformation memory priorityModeInfo = s.priorityModeInfo;
        if (priorityModeInfo.activated) {
            require(msg.sender == priorityModeInfo.permissionlessValidator, Unauthorized(msg.sender));
        } else {
            require(s.validators[msg.sender], Unauthorized(msg.sender));
        }
        _;
    }

    modifier onlyChainTypeManager() {
        if (msg.sender != s.chainTypeManager) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyBridgehub() {
        if (msg.sender != s.bridgehub) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyInteropCenter() {
        if (msg.sender != L2_INTEROP_CENTER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyL2ChainAssetHandler() {
        if (msg.sender != L2_CHAIN_ASSET_HANDLER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyChainAssetHandler() {
        if (msg.sender != IL1Bridgehub(s.bridgehub).chainAssetHandler()) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyAdminOrChainTypeManager() {
        if (msg.sender != s.admin && msg.sender != s.chainTypeManager) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyAdminOrChainTypeManagerOrValidator() {
        if (msg.sender != s.admin && msg.sender != s.chainTypeManager && !s.validators[msg.sender]) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyValidatorOrChainTypeManager() {
        if (!s.validators[msg.sender] && msg.sender != s.chainTypeManager) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlySettlementLayer() {
        if (s.settlementLayer != address(0)) {
            revert NotSettlementLayer();
        }
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyServiceTransaction() {
        IBridgehubBase bridgehub = IBridgehubBase(s.bridgehub);
        if (
            /// For registering chains in the L2Bridgehub. This is used for interop initiation.
            msg.sender != bridgehub.chainRegistrationSender() &&
            /// For sending the deposit-pause request to the settlement layer's L2ChainAssetHandler
            /// when a chain migrates away from it.
            msg.sender != address(bridgehub.chainAssetHandler())
        ) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Returns whether the priority queue is still active, i.e.
    /// the chain has not processed all transactions from it
    function _isPriorityQueueActive() internal view returns (bool) {
        return s.__DEPRECATED_priorityQueue.getFirstUnprocessedPriorityTx() < s.priorityTree.startIndex;
    }

    /// @notice Ensures that the queue is deactivated. Should be invoked
    /// whenever the chain migrates to another settlement layer.
    function _forceDeactivateQueue() internal {
        // We double check whether it is still active mainly to prevent
        // overriding `tail`/`head` on L1 deployment.
        if (_isPriorityQueueActive()) {
            uint256 startIndex = s.priorityTree.startIndex;
            s.__DEPRECATED_priorityQueue.head = startIndex;
            s.__DEPRECATED_priorityQueue.tail = startIndex;
        }
    }

    /// @notice Returns the real proof format the chain accepts under its current verifier and disabled proof systems.
    function _getProofMode() internal view returns (uint256) {
        return IZKsyncOSVerifier(address(s.verifier)).getProofMode(s.disabledProofSystems);
    }

    function _getTotalPriorityTxs() internal view returns (uint256) {
        return s.priorityTree.getTotalPriorityTxs();
    }

    function _getPriorityTxType() internal pure returns (uint256) {
        return ZKSYNC_OS_PRIORITY_OPERATION_L2_TX_TYPE;
    }

    function _getUpgradeTxType() internal pure returns (uint256) {
        return ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE;
    }

    /// @notice Returns the current runtime configuration hash. See {protocol-docs/chain-config.md}.
    function _getZKsyncOSChainConfigHash() internal view returns (bytes32) {
        return
            keccak256(
                abi.encodePacked(
                    s.chainId,
                    ZKSYNC_OS_FRI_PROOF_VERIFICATION_DISABLED,
                    uint256(_getZKsyncOSMaxTxGasLimit()),
                    uint256(s.pubdataContent),
                    uint256(s.zksyncOSL1TxFilteringEnabled ? 1 : 0),
                    uint256(s.zksyncOSLargeContractsEnabled ? 1 : 0)
                )
            );
    }

    /// @notice Returns the effective ZKsync OS single-transaction gas limit (EIP-7825).
    /// @dev `0` in storage means the value was never set explicitly (chains deployed before the
    /// field was introduced) and falls back to the default cap.
    function _getZKsyncOSMaxTxGasLimit() internal view returns (uint64) {
        uint64 storedMaxTxGasLimit = s.zksyncOSMaxTxGasLimit;
        return storedMaxTxGasLimit == 0 ? ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT : storedMaxTxGasLimit;
    }

    /// @notice Returns whether deposits are currently paused.
    /// @param _windowStart The delay from `pausedDepositsTimestamp` until deposits become paused.
    function _isInDepositsPausedWindow(uint256 _windowStart) internal view returns (bool) {
        uint256 timestamp = s.pausedDepositsTimestamp;
        return timestamp != 0 && timestamp + _windowStart <= block.timestamp;
    }

    /// @dev Checks that the batch hash is correct and matches the expected hash.
    /// @param _lastCommittedBatchData The last committed batch.
    /// @param _batchNumber The batch number to check.
    /// @param _checkLegacy Whether to check the legacy hash.
    function _checkBatchHashMismatch(
        IExecutor.StoredBatchInfo memory _lastCommittedBatchData,
        uint256 _batchNumber,
        bool _checkLegacy
    ) internal view {
        bytes32 cachedStoredBatchHashes = s.storedBatchHashes[_batchNumber];
        if (
            cachedStoredBatchHashes != StoredBatchHashing.hashStoredBatchInfo(_lastCommittedBatchData) &&
            (!_checkLegacy ||
                cachedStoredBatchHashes != StoredBatchHashing.hashLegacyStoredBatchInfo(_lastCommittedBatchData))
        ) {
            // incorrect previous batch data
            revert BatchHashMismatch(
                cachedStoredBatchHashes,
                StoredBatchHashing.hashStoredBatchInfo(_lastCommittedBatchData)
            );
        }
    }

    /// @notice Derives the price for L2 gas in base token to be paid.
    /// @param _l1GasPrice The gas price on L1
    /// @param _gasPerPubdata The price for each pubdata byte in L2 gas
    /// @return The price of L2 gas in the base token
    function _deriveL2GasPrice(uint256 _l1GasPrice, uint256 _gasPerPubdata) internal view returns (uint256) {
        if (s.baseTokenGasPriceMultiplierDenominator == 0) {
            revert BaseTokenGasPriceDenominatorNotSet();
        }

        return
            _deriveL2GasPriceFromParams({
                _feeParams: s.feeParams,
                _multiplierNominator: s.baseTokenGasPriceMultiplierNominator,
                _multiplierDenominator: s.baseTokenGasPriceMultiplierDenominator,
                _l1GasPrice: _l1GasPrice,
                _gasPerPubdata: _gasPerPubdata
            });
    }

    function _deriveL2GasPriceFromParams(
        FeeParams memory _feeParams,
        uint128 _multiplierNominator,
        uint128 _multiplierDenominator,
        uint256 _l1GasPrice,
        uint256 _gasPerPubdata
    ) internal pure returns (uint256) {
        uint256 l1GasPriceConverted = (_l1GasPrice * _multiplierNominator) / _multiplierDenominator;
        uint256 pubdataPriceBaseToken;
        if (_feeParams.pubdataPricingMode == PubdataPricingMode.Rollup) {
            // slither-disable-next-line divide-before-multiply
            pubdataPriceBaseToken = L1_GAS_PER_PUBDATA_BYTE * l1GasPriceConverted;
        }

        // slither-disable-next-line divide-before-multiply
        uint256 batchOverheadBaseToken = uint256(_feeParams.batchOverheadL1Gas) * l1GasPriceConverted;
        uint256 fullPubdataPriceBaseToken = pubdataPriceBaseToken +
            batchOverheadBaseToken / uint256(_feeParams.maxPubdataPerBatch);

        uint256 l2GasPrice = _feeParams.minimalL2GasPrice +
            batchOverheadBaseToken / uint256(_feeParams.maxL2GasPerBatch);
        uint256 minL2GasPriceBaseToken = (fullPubdataPriceBaseToken + _gasPerPubdata - 1) / _gasPerPubdata;

        return Math.max(l2GasPrice, minL2GasPriceBaseToken);
    }

    /// @notice Sets the DA validator pair with the given values.
    /// @dev It does not check for these values to be non-zero, since when migrating to a new settlement
    /// layer, we set them to zero.
    /// @param _l1DAValidator The address of the L1 DA validator.
    /// @param _l2DACommitmentScheme The scheme of the L2 DA commitment.
    function _setDAValidatorPair(address _l1DAValidator, L2DACommitmentScheme _l2DACommitmentScheme) internal {
        emit IAdmin.NewL1DAValidator(s.l1DAValidator, _l1DAValidator);
        emit IAdmin.NewL2DACommitmentScheme(s.l2DACommitmentScheme, _l2DACommitmentScheme);

        s.l1DAValidator = _l1DAValidator;
        s.l2DACommitmentScheme = _l2DACommitmentScheme;
    }

    /// @notice Reverts unless `_l1DAValidator` and `_l2DACommitmentScheme` can be set as the chain's DA validator pair.
    /// @param _rollupDAManager The RollupDAManager that lists the pairs a permanent rollup may use.
    /// @param _l1DAValidator The address of the L1 DA validator.
    /// @param _l2DACommitmentScheme The scheme of the L2 DA commitment.
    function _validateDAValidatorPair(
        RollupDAManager _rollupDAManager,
        address _l1DAValidator,
        L2DACommitmentScheme _l2DACommitmentScheme
    ) internal view {
        if (_l1DAValidator == address(0)) {
            revert L1DAValidatorAddressIsZero();
        }

        if (_l2DACommitmentScheme == L2DACommitmentScheme.NONE) {
            revert InvalidL2DACommitmentScheme(_l2DACommitmentScheme);
        }

        if (s.isPermanentRollup && !_rollupDAManager.isPairAllowed(_l1DAValidator, _l2DACommitmentScheme)) {
            revert InvalidDAForPermanentRollup();
        }
    }

    /// @notice Reverts unless the chain's pubdata content can be changed.
    function _validatePubdataContentChange() internal view {
        // A permanent rollup is locked to `FULL_PUBDATA` — its pubdata content can never be changed (in particular it
        // can never be relaxed to `LOGS_ONLY`), mirroring how the permanent-rollup flag itself is one-way.
        if (s.isPermanentRollup) {
            revert PubdataContentLockedForPermanentRollup();
        }
    }

    /// @notice Sets the chain's pubdata content.
    /// @param _pubdataContent The new pubdata content.
    function _setPubdataContent(PubdataContent _pubdataContent) internal {
        emit IAdmin.NewPubdataContent(s.pubdataContent, _pubdataContent);
        s.pubdataContent = _pubdataContent;
    }

    /// @notice Reverts unless `_newMaxTxGasLimit` can be set as the ZKsync OS single-transaction gas limit.
    /// @param _newMaxTxGasLimit The gas limit to check.
    function _validateZKsyncOSMaxTxGasLimit(uint64 _newMaxTxGasLimit) internal pure {
        // The cap may only be raised above Ethereum's EIP-7825 single-tx gas limit, never below.
        if (_newMaxTxGasLimit < ZKSYNC_OS_DEFAULT_MAX_TX_GAS_LIMIT) {
            revert ZKsyncOSMaxTxGasLimitTooLow();
        }
        // The cap must not exceed the ZKsync OS block gas limit: a higher value will halt the block production.
        if (_newMaxTxGasLimit > ZKSYNC_OS_MAX_BLOCK_GAS_LIMIT) {
            revert ZKsyncOSMaxTxGasLimitTooHigh();
        }
    }

    /// @notice Sets the ZKsync OS single-transaction gas limit.
    /// @param _newMaxTxGasLimit The new gas limit.
    function _setZKsyncOSMaxTxGasLimit(uint64 _newMaxTxGasLimit) internal {
        uint64 oldMaxTxGasLimit = _getZKsyncOSMaxTxGasLimit();
        s.zksyncOSMaxTxGasLimit = _newMaxTxGasLimit;
        emit IAdmin.NewZKsyncOSMaxTxGasLimit(oldMaxTxGasLimit, _newMaxTxGasLimit);
    }

    /// @notice Reverts unless L1 transaction filtering can be set to `_enabled`.
    /// @param _enabled Whether L1 transactions are to be filtered.
    function _validateZKsyncOSL1TxFiltering(bool _enabled) internal view {
        if (_enabled && s.priorityModeInfo.canBeActivated) {
            revert NotCompatibleWithPriorityMode();
        }
    }

    /// @notice Enables or disables L1 transaction filtering.
    /// @param _enabled Whether L1 transactions are filtered.
    function _setZKsyncOSL1TxFiltering(bool _enabled) internal {
        bool oldEnabled = s.zksyncOSL1TxFilteringEnabled;
        s.zksyncOSL1TxFilteringEnabled = _enabled;
        emit IAdmin.NewZKsyncOSL1TxFiltering(oldEnabled, _enabled);
    }

    /// @notice Enables or disables large contracts.
    /// @param _enabled Whether large contracts are enabled.
    function _setZKsyncOSLargeContractsEnabled(bool _enabled) internal {
        bool oldEnabled = s.zksyncOSLargeContractsEnabled;
        s.zksyncOSLargeContractsEnabled = _enabled;
        emit IAdmin.NewZKsyncOSLargeContracts(oldEnabled, _enabled);
    }

    /// @notice Enforces the configuration-update boundary described in {protocol-docs/chain-config.md}.
    function _enforceNoUnverifiedBatchesForChainConfigUpdate() internal view {
        if (s.totalBatchesCommitted != s.totalBatchesVerified) {
            revert ZKsyncOSChainConfigUpdateWithUnverifiedBatches(s.totalBatchesVerified, s.totalBatchesCommitted);
        }
    }

    /// @notice Reverts committed, unexecuted batches.
    /// @param _newLastBatch The batch number after which batches should be reverted.
    function _revertBatches(uint256 _newLastBatch) internal {
        if (s.totalBatchesCommitted < _newLastBatch) {
            revert RevertedBatchNotAfterNewLastBatch();
        }
        if (_newLastBatch < s.totalBatchesExecuted) {
            revert CantRevertExecutedBatch();
        }

        if (_newLastBatch < s.totalBatchesVerified) {
            s.totalBatchesVerified = _newLastBatch;
        }
        s.totalBatchesCommitted = _newLastBatch;

        // Reset the batch number of the executed system contracts upgrade transaction if the batch
        // where the system contracts upgrade was committed is among the reverted batches.
        if (s.l2SystemContractsUpgradeBatchNumber > _newLastBatch) {
            delete s.l2SystemContractsUpgradeBatchNumber;
        }

        emit IExecutor.BlocksRevert(s.totalBatchesCommitted, s.totalBatchesVerified, s.totalBatchesExecuted);
    }
}
