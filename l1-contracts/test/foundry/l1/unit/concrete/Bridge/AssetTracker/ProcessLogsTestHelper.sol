// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {
    L2Log,
    InteropBundle,
    InteropCall,
    BundleAttributes,
    BUNDLE_IDENTIFIER,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION
} from "contracts/common/Messaging.sol";
import {
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IAssetTrackerDataEncoding} from "contracts/bridge/asset-tracker/IAssetTrackerDataEncoding.sol";
import {InteropCallExecutedMessage} from "contracts/common/Messaging.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, L2_TO_L1_LOGS_MERKLE_TREE_DEPTH} from "contracts/common/Config.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {DynamicIncrementalMerkleMemory} from "contracts/common/libraries/DynamicIncrementalMerkleMemory.sol";
import {ProcessLogsInput} from "contracts/state-transition/chain-interfaces/IExecutor.sol";

import {GWAssetTrackerTestHelper} from "./GWAssetTracker.t.sol";

/// @title ProcessLogsTestHelper
/// @notice Reusable helpers for composing L2 logs, InteropBundle messages, and ProcessLogsInput structs in tests.
library ProcessLogsTestHelper {
    using DynamicIncrementalMerkleMemory for DynamicIncrementalMerkleMemory.Bytes32PushTree;

    /// @notice Computes the Merkle root from an array of L2Log structs.
    function buildLogsMerkleRoot(L2Log[] memory _logs) internal pure returns (bytes32) {
        DynamicIncrementalMerkleMemory.Bytes32PushTree memory tree;
        tree.createTree(L2_TO_L1_LOGS_MERKLE_TREE_DEPTH);
        tree.setup(L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH);

        for (uint256 i = 0; i < _logs.length; i++) {
            bytes32 hashedLog = MessageHashing.getLeafHashFromLog(_logs[i]);
            tree.push(hashedLog);
        }

        tree.extendUntilEnd();
        return tree.root();
    }

    /// @notice Creates an L2Log for an InteropCenter message (via L2_TO_L1_MESSENGER).
    /// @param _txNumberInBatch The transaction number in the batch for this log.
    /// @param _message The raw message bytes (BUNDLE_IDENTIFIER-prefixed encoded InteropBundle).
    function createInteropCenterLog(
        uint16 _txNumberInBatch,
        bytes memory _message
    ) internal pure returns (L2Log memory) {
        return
            L2Log({
                l2ShardId: 0,
                isService: true,
                txNumberInBatch: _txNumberInBatch,
                sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
                key: bytes32(uint256(uint160(L2_INTEROP_CENTER_ADDR))),
                value: keccak256(_message)
            });
    }

    /// @notice Creates a minimal InteropBundle with the given number of simple calls.
    /// @dev Calls have `from` set to address(1) (not L2_ASSET_ROUTER_ADDR), so they are
    ///      skipped by _handleInteropCenterMessage (no balance processing), but still
    ///      counted for settlement fees.
    /// @param _sourceChainId Source chain ID.
    /// @param _destinationChainId Destination chain ID.
    /// @param _destinationBaseTokenAssetId Base token asset ID of the destination chain.
    /// @param _numCalls Number of calls in the bundle.
    /// @param _salt Salt for bundle uniqueness.
    function createSimpleInteropBundle(
        uint256 _sourceChainId,
        uint256 _destinationChainId,
        bytes32 _destinationBaseTokenAssetId,
        uint256 _numCalls,
        bytes32 _salt
    ) internal pure returns (InteropBundle memory bundle) {
        InteropCall[] memory calls = new InteropCall[](_numCalls);
        for (uint256 i = 0; i < _numCalls; i++) {
            calls[i] = InteropCall({
                version: INTEROP_CALL_VERSION,
                shadowAccount: false,
                to: address(0xdead),
                from: address(1), // Not L2_ASSET_ROUTER_ADDR => skipped by _processInteropCall
                value: 0,
                data: ""
            });
        }

        bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: _sourceChainId,
            destinationChainId: _destinationChainId,
            destinationBaseTokenAssetId: _destinationBaseTokenAssetId,
            interopBundleSalt: _salt,
            calls: calls,
            bundleAttributes: BundleAttributes({executionAddress: "", unbundlerAddress: "", useFixedFee: false})
        });
    }

    /// @notice Encodes an InteropBundle into the message format expected by processLogsAndMessages.
    /// @dev Prepends BUNDLE_IDENTIFIER (0x01) to the ABI-encoded bundle.
    function encodeInteropCenterMessage(InteropBundle memory _bundle) internal pure returns (bytes memory) {
        return bytes.concat(BUNDLE_IDENTIFIER, abi.encode(_bundle));
    }

    /// @notice Creates a minimal InteropBundle whose calls each carry a non-zero base-token value.
    /// @dev Calls have `from` set to address(1) (not L2_ASSET_ROUTER_ADDR), so asset-router
    ///      processing is skipped.  The entire value is counted as base-token transfer.
    function createInteropBundleWithBaseTokenValue(
        uint256 _sourceChainId,
        uint256 _destinationChainId,
        bytes32 _destinationBaseTokenAssetId,
        uint256 _numCalls,
        uint256 _valuePerCall,
        bytes32 _salt
    ) internal pure returns (InteropBundle memory bundle) {
        InteropCall[] memory calls = new InteropCall[](_numCalls);
        for (uint256 i = 0; i < _numCalls; i++) {
            calls[i] = InteropCall({
                version: INTEROP_CALL_VERSION,
                shadowAccount: false,
                to: address(0xdead),
                from: address(1), // Not L2_ASSET_ROUTER_ADDR => asset processing skipped
                value: _valuePerCall,
                data: ""
            });
        }
        bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: _sourceChainId,
            destinationChainId: _destinationChainId,
            destinationBaseTokenAssetId: _destinationBaseTokenAssetId,
            interopBundleSalt: _salt,
            calls: calls,
            bundleAttributes: BundleAttributes({executionAddress: "", unbundlerAddress: "", useFixedFee: false})
        });
    }

    /// @notice Creates an L2Log for an InteropHandler message (via L2_TO_L1_MESSENGER).
    function createInteropHandlerLog(
        uint16 _txNumberInBatch,
        bytes memory _message
    ) internal pure returns (L2Log memory) {
        return
            L2Log({
                l2ShardId: 0,
                isService: true,
                txNumberInBatch: _txNumberInBatch,
                sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
                key: bytes32(uint256(uint160(L2_INTEROP_HANDLER_ADDR))),
                value: keccak256(_message)
            });
    }

    /// @notice Encodes an InteropCallExecutedMessage into the L2→L1 message format expected by
    ///         processLogsAndMessages when handling InteropHandler logs.
    function encodeInteropCallExecutedMessage(
        InteropCallExecutedMessage memory _msg
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(IAssetTrackerDataEncoding.receiveInteropCallExecuted, (_msg));
    }

    /// @notice Builds a complete ProcessLogsInput with correct Merkle root and chainBatchRoot.
    /// @param _gwAssetTracker The GWAssetTrackerTestHelper instance (needed for getEmptyMultichainBatchRoot).
    /// @param _chainId The settling chain ID.
    /// @param _batchNumber Batch number.
    /// @param _logs Array of L2Log entries.
    /// @param _messages Array of message bytes (matching the messenger logs).
    /// @param _settlementFeePayer The address paying settlement fees (or address(0) for none).
    function buildProcessLogsInput(
        GWAssetTrackerTestHelper _gwAssetTracker,
        uint256 _chainId,
        uint256 _batchNumber,
        L2Log[] memory _logs,
        bytes[] memory _messages,
        address _settlementFeePayer
    ) internal returns (ProcessLogsInput memory) {
        bytes32 emptyMultichainBatchRoot = _gwAssetTracker.getEmptyMultichainBatchRoot(_chainId);
        bytes32 logsRoot = buildLogsMerkleRoot(_logs);
        bytes32 chainBatchRoot = keccak256(bytes.concat(logsRoot, emptyMultichainBatchRoot));

        return
            ProcessLogsInput({
                chainId: _chainId,
                batchNumber: _batchNumber,
                logs: _logs,
                messages: _messages,
                chainBatchRoot: chainBatchRoot,
                multichainBatchRoot: emptyMultichainBatchRoot,
                settlementFeePayer: _settlementFeePayer
            });
    }
}
