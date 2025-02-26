// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IAssetTracker} from "./IAssetTracker.sol";
import {WritePriorityOpParams, L2CanonicalTransaction, L2Message, L2Log, TxStatus, BridgehubL2TransactionRequest} from "../../common/Messaging.sol";
import {L2_INTEROP_CENTER_ADDR, L2_ASSET_ROUTER_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {InteropBundle, InteropCall} from "../../common/Messaging.sol";
import {DataEncoding} from "../../common/libraries/DataEncoding.sol";
import {IAssetRouterBase} from "../asset-router/IAssetRouterBase.sol";
import {INativeTokenVault} from "../ntv/INativeTokenVault.sol";
import {OriginChainIdNotFound, Unauthorized, ZeroAddress, NoFundsTransferred, InsufficientChainBalance, WithdrawFailed, ReconstructionMismatch, InvalidMessage, InvalidInteropCalldata} from "../../common/L1ContractErrors.sol";
import {IMessageRoot} from "../../bridgehub/IMessageRoot.sol";
import {ProcessLogsInput} from "../../state-transition/chain-interfaces/IExecutor.sol";
import {DynamicIncrementalMerkle} from "../../common/libraries/DynamicIncrementalMerkle.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, L2_TO_L1_LOGS_MERKLE_TREE_LEAVES} from "../../common/Config.sol";
import {BUNDLE_IDENTIFIER, TRIGGER_IDENTIFIER} from "../../common/Messaging.sol";

contract AssetTracker is IAssetTracker {
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    IAssetRouterBase public immutable ASSET_ROUTER;

    INativeTokenVault public immutable NATIVE_TOKEN_VAULT;

    IMessageRoot public immutable MESSAGE_ROOT;

    /// @dev Maps token balances for each chain to prevent unauthorized spending across ZK chains.
    /// This serves as a security measure until hyperbridging is implemented.
    /// NOTE: this function may be removed in the future, don't rely on it!
    mapping(uint256 chainId => mapping(bytes32 assetId => uint256 balance)) public chainBalance;

    mapping(uint256 chainId => mapping(bytes32 assetId => bool isMinter)) public isMinterChain;

    // for now
    mapping(bytes32 assetId => uint256 originChainId) public originChainId;

    constructor(address _assetRouter, address _nativeTokenVault, address _messageRoot) {
        ASSET_ROUTER = IAssetRouterBase(_assetRouter);
        NATIVE_TOKEN_VAULT = INativeTokenVault(_nativeTokenVault);
        MESSAGE_ROOT = IMessageRoot(_messageRoot);
    }

    function initialize() external {
        // TODO: implement
    }

    function migrateChainBalance(uint256 _chainId, bytes32 _assetId) external {
        // TODO: implement
    }

    function handleChainBalanceIncrease(uint256 _chainId, bytes32 _assetId, uint256 _amount, bool _isNative) external {
        chainBalance[_chainId][_assetId] += _amount;
    }

    function handleChainBalanceDecrease(uint256 _chainId, bytes32 _assetId, uint256 _amount, bool _isNative) external {
        // Check that the chain has sufficient balance
        if (chainBalance[_chainId][_assetId] < _amount) {
            revert InsufficientChainBalance();
        }
        chainBalance[_chainId][_assetId] -= _amount;
    }

    /// note we don't process L1 txs here, since we can do that when accepting the tx.
    function processLogsAndMessages(ProcessLogsInput calldata _processLogsInputs) external {
        uint256 msgCount = 0;
        DynamicIncrementalMerkle.Bytes32PushTree memory reconstructedLogsTree = DynamicIncrementalMerkle
            .Bytes32PushTree(
                0,
                new bytes32[](L2_TO_L1_LOGS_MERKLE_TREE_LEAVES),
                new bytes32[](L2_TO_L1_LOGS_MERKLE_TREE_LEAVES),
                0,
                0
            ); // todo 100 to const
        reconstructedLogsTree.setupMemory(L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH);
        for (uint256 logCount = 0; logCount < _processLogsInputs.logs.length; logCount++) {
            L2Log memory log = _processLogsInputs.logs[logCount];
            bytes32 hashedLog = keccak256(
                // solhint-disable-next-line func-named-parameters
                abi.encodePacked(log.l2ShardId, log.isService, log.txNumberInBatch, log.sender, log.key, log.value)
            );
            reconstructedLogsTree.pushMemory(hashedLog);
            if (log.sender != L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR) {
                continue;
            }
            if (log.key != bytes32(uint256(uint160(L2_INTEROP_CENTER_ADDR)))) {
                msgCount++;
                continue;
            }
            bytes memory message = _processLogsInputs.messages[msgCount];
            msgCount++;

            if (log.value != keccak256(message)) {
                revert InvalidMessage();
            }
            if (message[0] != BUNDLE_IDENTIFIER) {
                continue;
            }

            InteropBundle memory interopBundle = this.parseInteropBundle(message);

            // handle msg.value call separately
            InteropCall memory interopCall = interopBundle.calls[0];
            for (uint256 callCount = 1; callCount < interopBundle.calls.length; callCount++) {
                interopCall = interopBundle.calls[callCount];

                // e.g. for direct calls we just skip
                if (interopCall.from != L2_ASSET_ROUTER_ADDR) {
                    continue;
                }

                if (bytes4(interopCall.data) != IAssetRouterBase.finalizeDeposit.selector) {
                    revert InvalidInteropCalldata(bytes4(interopCall.data));
                }
                (uint256 fromChainId, bytes32 assetId, bytes memory transferData) = this.parseInteropCall(
                    interopCall.data
                );
                (, , , uint256 amount, bytes memory erc20Metadata) = DataEncoding.decodeBridgeMintData(transferData);
                (uint256 tokenOriginChainId, , , ) = this.parseTokenData(erc20Metadata);

                // if (!isMinterChain[fromChainId][assetId]) {
                if (tokenOriginChainId != fromChainId) {
                    chainBalance[fromChainId][assetId] -= amount;
                }
                // if (!isMinterChain[interopBundle.destinationChainId][assetId]) {
                if (tokenOriginChainId != interopBundle.destinationChainId) {
                    chainBalance[interopBundle.destinationChainId][assetId] += amount;
                }
            }

            // kl todo add change minter role here
        }
        bytes32 localLogsRootHash;
        if (_processLogsInputs.logs.length == 0) {
            localLogsRootHash = L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH;
        } else {
            localLogsRootHash = reconstructedLogsTree.rootMemory();
        }
        bytes32 chainBatchRootHash = keccak256(bytes.concat(localLogsRootHash, _processLogsInputs.messageRoot));

        if (chainBatchRootHash != _processLogsInputs.chainBatchRoot) {
            // emit ReconstructionMismatch(localLogsRootHash, _processLogsInputs.messageRoot);
            revert ReconstructionMismatch(chainBatchRootHash, _processLogsInputs.chainBatchRoot);
        }

        _appendChainBatchRoot(_processLogsInputs.chainId, _processLogsInputs.batchNumber, chainBatchRootHash);
    }

    function parseInteropBundle(bytes calldata _bundleData) external pure returns (InteropBundle memory interopBundle) {
        interopBundle = abi.decode(_bundleData[1:], (InteropBundle));
    }

    function parseInteropCall(
        bytes calldata _callData
    ) external pure returns (uint256 fromChainId, bytes32 assetId, bytes memory transferData) {
        (fromChainId, assetId, transferData) = abi.decode(_callData[4:], (uint256, bytes32, bytes));
    }

    function parseTokenData(
        bytes calldata _tokenData
    ) external pure returns (uint256 originChainId, bytes memory name, bytes memory symbol, bytes memory decimals) {
        (originChainId, name, symbol, decimals) = DataEncoding.decodeTokenData(_tokenData);
    }

    /// @notice Appends the batch message root to the global message.
    /// @param _batchNumber The number of the batch
    /// @param _messageRoot The root of the merkle tree of the messages to L1.
    /// @dev The logic of this function depends on the settlement layer as we support
    /// message root aggregation only on non-L1 settlement layers for ease for migration.
    function _appendChainBatchRoot(uint256 _chainId, uint256 _batchNumber, bytes32 _messageRoot) internal {
        MESSAGE_ROOT.addChainBatchRoot(_chainId, _batchNumber, _messageRoot);
    }
}
