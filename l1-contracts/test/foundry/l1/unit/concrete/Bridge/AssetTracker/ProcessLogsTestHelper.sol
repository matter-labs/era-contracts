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
    L2_INTEROP_HANDLER_ADDR,
    L2_ASSET_ROUTER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IAssetTrackerDataEncoding} from "contracts/bridge/asset-tracker/IAssetTrackerDataEncoding.sol";
import {InteropCallExecutedMessage} from "contracts/common/Messaging.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
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
        return _createMessengerLog(_txNumberInBatch, L2_INTEROP_CENTER_ADDR, _message);
    }

    /// @notice Creates a minimal InteropBundle with the given number of simple zero-value calls.
    /// @dev Calls have `from` set to address(1) (not L2_ASSET_ROUTER_ADDR), so they are
    ///      skipped by _handleInteropCenterMessage (no balance processing), but still
    ///      counted for settlement fees.
    function createSimpleInteropBundle(
        uint256 _sourceChainId,
        uint256 _destinationChainId,
        bytes32 _destinationBaseTokenAssetId,
        uint256 _numCalls,
        bytes32 _salt
    ) internal pure returns (InteropBundle memory) {
        return
            createInteropBundleWithBaseTokenValue(
                _sourceChainId,
                _destinationChainId,
                _destinationBaseTokenAssetId,
                _numCalls,
                0,
                _salt
            );
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
        return _createMessengerLog(_txNumberInBatch, L2_INTEROP_HANDLER_ADDR, _message);
    }

    /// @notice Encodes an InteropCallExecutedMessage into the L2→L1 message format expected by
    ///         processLogsAndMessages when handling InteropHandler logs.
    function encodeInteropCallExecutedMessage(
        InteropCallExecutedMessage memory _msg
    ) internal pure returns (bytes memory) {
        return abi.encodeCall(IAssetTrackerDataEncoding.receiveInteropCallExecuted, (_msg));
    }

    /// @notice Creates an L2Log for an asset router withdrawal (L2→L1).
    function createAssetRouterWithdrawalLog(
        uint16 _txNumberInBatch,
        bytes memory _message
    ) internal pure returns (L2Log memory) {
        return _createMessengerLog(_txNumberInBatch, L2_ASSET_ROUTER_ADDR, _message);
    }

    /// @notice Creates an L2Log for a legacy bridge withdrawal.
    /// @param _legacyBridge The legacy bridge address (used as log key).
    function createLegacyBridgeLog(
        uint16 _txNumberInBatch,
        address _legacyBridge,
        bytes memory _message
    ) internal pure returns (L2Log memory) {
        return _createMessengerLog(_txNumberInBatch, _legacyBridge, _message);
    }

    /// @dev Creates a service L2Log from L2_TO_L1_MESSENGER with the given key address and message hash.
    function _createMessengerLog(
        uint16 _txNumberInBatch,
        address _keyAddr,
        bytes memory _message
    ) private pure returns (L2Log memory) {
        return
            L2Log({
                l2ShardId: 0,
                isService: true,
                txNumberInBatch: _txNumberInBatch,
                sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
                key: bytes32(uint256(uint160(_keyAddr))),
                value: keccak256(_message)
            });
    }

    /// @notice Creates an interop bundle with a single asset-router call.
    /// @dev The call has `from = L2_ASSET_ROUTER_ADDR` so it triggers AR balance processing.
    function createInteropBundleWithArCall(
        uint256 _sourceChainId,
        uint256 _destinationChainId,
        bytes32 _destinationBaseTokenAssetId,
        bytes memory _arCallData,
        bytes32 _salt
    ) internal pure returns (InteropBundle memory bundle) {
        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: L2_ASSET_ROUTER_ADDR,
            from: L2_ASSET_ROUTER_ADDR,
            value: 0,
            data: _arCallData
        });
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

    /// @notice Builds BridgeMintData for the given origin chain/token/amount.
    function buildTransferData(
        uint256 _originChainId,
        address _originToken,
        uint256 _amount
    ) internal pure returns (bytes memory) {
        bytes memory erc20Metadata = DataEncoding.encodeTokenData(
            _originChainId,
            abi.encode("TestToken"),
            abi.encode("TT"),
            abi.encode(uint8(18))
        );
        return DataEncoding.encodeBridgeMintData(address(0), address(0xdead), _originToken, _amount, erc20Metadata);
    }

    /// @notice Builds asset-router interop call data: finalizeDeposit(fromChainId, assetId, transferData).
    function buildArCallData(
        bytes32 _assetId,
        uint256 _fromChainId,
        uint256 _originChainId,
        address _originToken,
        uint256 _amount
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                AssetRouterBase.finalizeDeposit.selector,
                abi.encode(_fromChainId, _assetId, buildTransferData(_originChainId, _originToken, _amount))
            );
    }

    /// @notice Builds a ProcessLogsInput for the source chain settling an interop bundle with one AR call.
    function buildInteropBundleInput(
        GWAssetTrackerTestHelper _gwAssetTracker,
        uint256 _srcChainId,
        uint256 _dstChainId,
        bytes32 _destBaseTokenAssetId,
        bytes32 _assetId,
        uint256 _originChainId,
        address _originToken,
        uint256 _amount
    ) internal returns (ProcessLogsInput memory) {
        bytes memory arCallData = buildArCallData(_assetId, _srcChainId, _originChainId, _originToken, _amount);
        return
            _buildBundleInputFromBundle(
                _gwAssetTracker,
                _srcChainId,
                createInteropBundleWithArCall(
                    _srcChainId,
                    _dstChainId,
                    _destBaseTokenAssetId,
                    arCallData,
                    keccak256("salt")
                )
            );
    }

    /// @notice Builds a ProcessLogsInput for the source chain settling an interop bundle
    ///         whose calls each carry base-token value (no AR calls).
    function buildBaseTokenBundleInput(
        GWAssetTrackerTestHelper _gwAssetTracker,
        uint256 _srcChainId,
        uint256 _dstChainId,
        bytes32 _destBaseTokenAssetId,
        uint256 _numCalls,
        uint256 _valuePerCall
    ) internal returns (ProcessLogsInput memory) {
        return
            _buildBundleInputFromBundle(
                _gwAssetTracker,
                _srcChainId,
                createInteropBundleWithBaseTokenValue(
                    _srcChainId,
                    _dstChainId,
                    _destBaseTokenAssetId,
                    _numCalls,
                    _valuePerCall,
                    keccak256("salt")
                )
            );
    }

    /// @notice Builds a ProcessLogsInput for the destination chain confirming an AR-call execution.
    function buildInteropHandlerInput(
        GWAssetTrackerTestHelper _gwAssetTracker,
        uint256 _dstChainId,
        bytes32 _destBaseTokenAssetId,
        bytes32 _assetId,
        uint256 _fromChainId,
        uint256 _originChainId,
        address _originToken,
        uint256 _amount
    ) internal returns (ProcessLogsInput memory) {
        return
            _buildHandlerInputFromCall(
                _gwAssetTracker,
                _dstChainId,
                _destBaseTokenAssetId,
                InteropCall({
                    version: INTEROP_CALL_VERSION,
                    shadowAccount: false,
                    to: L2_ASSET_ROUTER_ADDR,
                    from: L2_ASSET_ROUTER_ADDR,
                    value: 0,
                    data: buildArCallData(_assetId, _fromChainId, _originChainId, _originToken, _amount)
                })
            );
    }

    /// @notice Builds a ProcessLogsInput for the destination chain confirming a base-token-only execution.
    function buildBaseTokenHandlerInput(
        GWAssetTrackerTestHelper _gwAssetTracker,
        uint256 _dstChainId,
        bytes32 _destBaseTokenAssetId,
        uint256 _baseTokenValue
    ) internal returns (ProcessLogsInput memory) {
        return
            _buildHandlerInputFromCall(
                _gwAssetTracker,
                _dstChainId,
                _destBaseTokenAssetId,
                InteropCall({
                    version: INTEROP_CALL_VERSION,
                    shadowAccount: false,
                    to: address(0xdead),
                    from: address(1),
                    value: _baseTokenValue,
                    data: ""
                })
            );
    }

    /// @dev Encodes a bundle as a message, wraps it in a single log, and builds the ProcessLogsInput.
    function _buildBundleInputFromBundle(
        GWAssetTrackerTestHelper _gwAssetTracker,
        uint256 _srcChainId,
        InteropBundle memory _bundle
    ) private returns (ProcessLogsInput memory) {
        bytes memory message = encodeInteropCenterMessage(_bundle);
        L2Log[] memory logs = new L2Log[](1);
        logs[0] = createInteropCenterLog(0, message);
        bytes[] memory messages = new bytes[](1);
        messages[0] = message;
        return buildProcessLogsInput(_gwAssetTracker, _srcChainId, 1, logs, messages, address(0));
    }

    /// @dev Wraps an InteropCall in an executed message, creates the handler log, and builds the ProcessLogsInput.
    function _buildHandlerInputFromCall(
        GWAssetTrackerTestHelper _gwAssetTracker,
        uint256 _dstChainId,
        bytes32 _destBaseTokenAssetId,
        InteropCall memory _call
    ) private returns (ProcessLogsInput memory) {
        bytes memory handlerMsg = encodeInteropCallExecutedMessage(
            InteropCallExecutedMessage({destinationBaseTokenAssetId: _destBaseTokenAssetId, interopCall: _call})
        );
        L2Log[] memory logs = new L2Log[](1);
        logs[0] = createInteropHandlerLog(0, handlerMsg);
        bytes[] memory messages = new bytes[](1);
        messages[0] = handlerMsg;
        return buildProcessLogsInput(_gwAssetTracker, _dstChainId, 1, logs, messages, address(0));
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
