// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ZKChainStorage} from "../ZKChainStorage.sol";
import {ReentrancyGuard} from "../../../common/ReentrancyGuard.sol";
import {PriorityQueue} from "../../libraries/PriorityQueue.sol";
import {PriorityTree} from "../../libraries/PriorityTree.sol";
import {NotSettlementLayer} from "../../L1StateTransitionErrors.sol";
import {Unauthorized} from "../../../common/L1ContractErrors.sol";
import {IBridgehub} from "../../../bridgehub/IBridgehub.sol";
import {IInteropCenter} from "../../../interop/IInteropCenter.sol";

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
        if ((msg.sender != s.bridgehub) && (msg.sender != s.interopCenter)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyChainAssetHandler() {
        if (msg.sender != IBridgehub(s.bridgehub).chainAssetHandler()) {
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
        IBridgehub bridgehub = IBridgehub(s.bridgehub);
        if (
            /// Multiple purposes.
            /// 1. Allow EVM emulation.
            /// 2. saveV30UpgradeGatewayBlockNumberOnL2, so disable interop for pre V30 batches.
            msg.sender != address(this) &&
            /// For registering chains in the L2Bridgehub. This is used for interop initiation.
            msg.sender != bridgehub.chainRegistrationSender() &&
            /// For sending the token balance migration confirmation txs to L2s and the Gateway.
            msg.sender != address(IInteropCenter(bridgehub.interopCenter()).assetTracker()) &&
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
}
