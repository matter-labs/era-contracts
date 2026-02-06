// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKChainStorage, PriorityModeInformation, FeeParams, PubdataPricingMode} from "../ZKChainStorage.sol";
import {ReentrancyGuard} from "../../../common/ReentrancyGuard.sol";
import {PriorityQueue} from "../../libraries/PriorityQueue.sol";
import {PriorityTree} from "../../libraries/PriorityTree.sol";
import {NotSettlementLayer} from "../../L1StateTransitionErrors.sol";
import {BaseTokenGasPriceDenominatorNotSet, Unauthorized, OnlyNormalMode, OnlyPriorityMode} from "../../../common/L1ContractErrors.sol";
import {L2_INTEROP_CENTER_ADDR, GW_ASSET_TRACKER_ADDR} from "../../../common/l2-helpers/L2ContractAddresses.sol";
import {IL1Bridgehub} from "../../../core/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "../../../core/bridgehub/IBridgehubBase.sol";
import {Math} from "@openzeppelin/contracts-v4/utils/math/Math.sol";
import {L1_GAS_PER_PUBDATA_BYTE, PRIORITY_OPERATION_L2_TX_TYPE, SYSTEM_UPGRADE_L2_TX_TYPE, ZKSYNC_OS_PRIORITY_OPERATION_L2_TX_TYPE, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE, L2DACommitmentScheme, DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH} from "../../../common/Config.sol";
import {RevertedBatchNotAfterNewLastBatch, CantRevertExecutedBatch} from "../../../common/L1ContractErrors.sol";
import {IAdmin} from "../../chain-interfaces/IAdmin.sol";
import {IExecutor} from "../../chain-interfaces/IExecutor.sol";

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

    modifier onlyBridgehubOrInteropCenter() {
        if ((msg.sender != s.bridgehub) && (msg.sender != L2_INTEROP_CENTER_ADDR)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyGatewayAssetTracker() {
        if (msg.sender != GW_ASSET_TRACKER_ADDR) {
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
            /// Purposes.
            /// 1. Allow EVM emulation.
            msg.sender != address(this) &&
            /// For registering chains in the L2Bridgehub. This is used for interop initiation.
            msg.sender != bridgehub.chainRegistrationSender() &&
            /// For sending the token balance migration confirmation txs to L2s and the Gateway.
            /// confirmMigrationOnL2, confirmMigrationOnGateway.
            msg.sender != address(s.assetTracker) &&
            /// 1. For setting the legacy shared bridge in the L2Asset Tracker.
            /// 2. Also for sending the demarcation txs for token balance migration. It might be deleted.
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

    function _getTotalPriorityTxs() internal view returns (uint256) {
        return s.priorityTree.getTotalPriorityTxs();
    }

    function _getPriorityTxType() internal view returns (uint256) {
        return s.zksyncOS ? ZKSYNC_OS_PRIORITY_OPERATION_L2_TX_TYPE : PRIORITY_OPERATION_L2_TX_TYPE;
    }

    function _getUpgradeTxType() internal view returns (uint256) {
        return s.zksyncOS ? ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE : SYSTEM_UPGRADE_L2_TX_TYPE;
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
            batchOverheadBaseToken /
            uint256(_feeParams.maxPubdataPerBatch);

        uint256 l2GasPrice = _feeParams.minimalL2GasPrice +
            batchOverheadBaseToken /
            uint256(_feeParams.maxL2GasPerBatch);
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

    /// @notice Reverts uncommitted batches
    /// @param _newLastBatch The batch number after which batches should be reverted.
    function _revertBatches(uint256 _newLastBatch) internal {
        if (s.totalBatchesCommitted < _newLastBatch) {
            revert RevertedBatchNotAfterNewLastBatch();
        }
        if (_newLastBatch < s.totalBatchesExecuted) {
            revert CantRevertExecutedBatch();
        }

        s.precommitmentForTheLatestBatch = DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH;

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
