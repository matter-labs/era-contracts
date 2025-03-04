// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts-v4/utils/math/Math.sol";

import {IMailbox} from "../../chain-interfaces/IMailbox.sol";
import {IChainTypeManager} from "../../IChainTypeManager.sol";
import {IBridgehub} from "../../../bridgehub/IBridgehub.sol";

import {ITransactionFilterer} from "../../chain-interfaces/ITransactionFilterer.sol";
import {Merkle} from "../../../common/libraries/Merkle.sol";
import {PriorityQueue, PriorityOperation} from "../../libraries/PriorityQueue.sol";
import {PriorityTree} from "../../libraries/PriorityTree.sol";
import {TransactionValidator} from "../../libraries/TransactionValidator.sol";
import {WritePriorityOpParams, L2CanonicalTransaction, L2Message, L2Log, TxStatus, BridgehubL2TransactionRequest} from "../../../common/Messaging.sol";
import {MessageHashing} from "../../../common/libraries/MessageHashing.sol";
import {FeeParams, PubdataPricingMode} from "../ZKChainStorage.sol";
import {UncheckedMath} from "../../../common/libraries/UncheckedMath.sol";
import {L2ContractHelper} from "../../../common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "../../../vendor/AddressAliasHelper.sol";
import {ZKChainBase} from "./ZKChainBase.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, L1_GAS_PER_PUBDATA_BYTE, L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, PRIORITY_OPERATION_L2_TX_TYPE, PRIORITY_EXPIRATION, MAX_NEW_FACTORY_DEPS, SETTLEMENT_LAYER_RELAY_SENDER, SUPPORTED_PROOF_METADATA_VERSION, SERVICE_TRANSACTION_SENDER} from "../../../common/Config.sol";
import {L2_BOOTLOADER_ADDRESS, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_BRIDGEHUB_ADDR} from "../../../common/L2ContractAddresses.sol";

import {IL1AssetRouter} from "../../../bridge/asset-router/IL1AssetRouter.sol";

import {MerklePathEmpty, OnlyEraSupported, BatchNotExecuted, HashedLogIsDefault, BaseTokenGasPriceDenominatorNotSet, TransactionNotAllowed, GasPerPubdataMismatch, TooManyFactoryDeps, MsgValueTooLow, InvalidProofLengthForFinalNode} from "../../../common/L1ContractErrors.sol";
import {NotL1, UnsupportedProofMetadataVersion, LocalRootIsZero, LocalRootMustBeZero, NotSettlementLayer, NotHyperchain} from "../../L1StateTransitionErrors.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZKChainBase} from "../../chain-interfaces/IZKChainBase.sol";

/// @title ZKsync Mailbox contract providing interfaces for L1 <-> L2 interaction.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract MailboxFacet is ZKChainBase, IMailbox {
    using UncheckedMath for uint256;
    using PriorityQueue for PriorityQueue.Queue;
    using PriorityTree for PriorityTree.Tree;

    /// @inheritdoc IZKChainBase
    string public constant override getName = "MailboxFacet";

    /// @dev Era's chainID
    uint256 internal immutable ERA_CHAIN_ID;

    /// @notice The chain id of L1. This contract can be deployed on multiple layers, but this value is still equal to the
    /// L1 that is at the most base layer.
    uint256 internal immutable L1_CHAIN_ID;

    modifier onlyL1() {
        if (block.chainid != L1_CHAIN_ID) {
            revert NotL1(block.chainid);
        }
        _;
    }

    constructor(uint256 _eraChainId, uint256 _l1ChainId) {
        ERA_CHAIN_ID = _eraChainId;
        L1_CHAIN_ID = _l1ChainId;
    }

    /// @inheritdoc IMailbox
    function bridgehubRequestL2Transaction(
        BridgehubL2TransactionRequest calldata _request
    ) external onlyBridgehub returns (bytes32 canonicalTxHash) {
        canonicalTxHash = _requestL2TransactionSender(_request);
    }

    /// @inheritdoc IMailbox
    function proveL2MessageInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) public view returns (bool) {
        return _proveL2LogInclusion(_batchNumber, _index, _L2MessageToLog(_message), _proof);
    }

    /// @inheritdoc IMailbox
    function proveL2LogInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Log calldata _log,
        bytes32[] calldata _proof
    ) external view returns (bool) {
        return _proveL2LogInclusion(_batchNumber, _index, _log, _proof);
    }

    /// @inheritdoc IMailbox
    function proveL1ToL2TransactionStatus(
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) public view returns (bool) {
        // Bootloader sends an L2 -> L1 log only after processing the L1 -> L2 transaction.
        // Thus, we can verify that the L1 -> L2 transaction was included in the L2 batch with specified status.
        //
        // The semantics of such L2 -> L1 log is always:
        // - sender = L2_BOOTLOADER_ADDRESS
        // - key = hash(L1ToL2Transaction)
        // - value = status of the processing transaction (1 - success & 0 - fail)
        // - isService = true (just a conventional value)
        // - l2ShardId = 0 (means that L1 -> L2 transaction was processed in a rollup shard, other shards are not available yet anyway)
        // - txNumberInBatch = number of transaction in the batch
        L2Log memory l2Log = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: _l2TxNumberInBatch,
            sender: L2_BOOTLOADER_ADDRESS,
            key: _l2TxHash,
            value: bytes32(uint256(_status))
        });
        return _proveL2LogInclusion(_l2BatchNumber, _l2MessageIndex, l2Log, _merkleProof);
    }

    function _parseProofMetadata(
        bytes32[] calldata _proof
    )
        internal
        pure
        returns (uint256 proofStartIndex, uint256 logLeafProofLen, uint256 batchLeafProofLen, bool finalProofNode)
    {
        bytes32 proofMetadata = _proof[0];

        // We support two formats of the proofs:
        // 1. The old format, where `_proof` is just a plain Merkle proof.
        // 2. The new format, where the first element of the `_proof` is encoded metadata, which consists of the following:
        // - first byte: metadata version (0x01).
        // - second byte: length of the log leaf proof (the proof that the log belongs to a batch).
        // - third byte: length of the batch leaf proof (the proof that the batch belongs to another settlement layer, if any).
        // - fourth byte: whether the current proof is the last in the links of recursive proofs for settlement layers.
        // - the rest of the bytes are zeroes.
        //
        // In the future the old version will be disabled, and only the new version will be supported.
        // For now, we need to support both for backwards compatibility. We distinguish between those based on whether the last 28 bytes are zeroes.
        // It is safe, since the elements of the proof are hashes and are unlikely to have 28 zero bytes in them.

        // We shift left by 4 bytes = 32 bits to remove the top 32 bits of the metadata.
        uint256 metadataAsUint256 = (uint256(proofMetadata) << 32);

        if (metadataAsUint256 == 0) {
            // It is the new version
            bytes1 metadataVersion = bytes1(proofMetadata);
            if (uint256(uint8(metadataVersion)) != SUPPORTED_PROOF_METADATA_VERSION) {
                revert UnsupportedProofMetadataVersion(uint256(uint8(metadataVersion)));
            }

            proofStartIndex = 1;
            logLeafProofLen = uint256(uint8(proofMetadata[1]));
            batchLeafProofLen = uint256(uint8(proofMetadata[2]));
            finalProofNode = uint256(uint8(proofMetadata[3])) != 0;
        } else {
            // It is the old version

            // The entire proof is a merkle path
            proofStartIndex = 0;
            logLeafProofLen = _proof.length;
            batchLeafProofLen = 0;
            finalProofNode = true;
        }

        if (finalProofNode && batchLeafProofLen != 0) {
            revert InvalidProofLengthForFinalNode();
        }
    }

    function extractSlice(
        bytes32[] calldata _proof,
        uint256 _left,
        uint256 _right
    ) internal pure returns (bytes32[] memory slice) {
        slice = new bytes32[](_right - _left);
        for (uint256 i = _left; i < _right; i = i.uncheckedInc()) {
            slice[i - _left] = _proof[i];
        }
    }

    /// @notice Extracts slice until the end of the array.
    /// @dev It is used in one place in order to circumvent the stack too deep error.
    function extractSliceUntilEnd(
        bytes32[] calldata _proof,
        uint256 _start
    ) internal pure returns (bytes32[] memory slice) {
        slice = extractSlice(_proof, _start, _proof.length);
    }

    /// @inheritdoc IMailbox
    function proveL2LeafInclusion(
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) external view override returns (bool) {
        return _proveL2LeafInclusion(_batchNumber, _leafProofMask, _leaf, _proof);
    }

    function _proveL2LeafInclusion(
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) internal view returns (bool) {
        if (_proof.length == 0) {
            revert MerklePathEmpty();
        }

        uint256 ptr = 0;
        bytes32 chainIdLeaf;
        {
            (
                uint256 proofStartIndex,
                uint256 logLeafProofLen,
                uint256 batchLeafProofLen,
                bool finalProofNode
            ) = _parseProofMetadata(_proof);
            ptr = proofStartIndex;

            bytes32 batchSettlementRoot = Merkle.calculateRootMemory(
                extractSlice(_proof, ptr, ptr + logLeafProofLen),
                _leafProofMask,
                _leaf
            );
            ptr += logLeafProofLen;

            // If the `finalProofNode` is true, then we assume that this is L1 contract of the top-level
            // in the aggregation, i.e. the batch root is stored here on L1.
            if (finalProofNode) {
                // Double checking that the batch has been executed.
                if (_batchNumber > s.totalBatchesExecuted) {
                    revert BatchNotExecuted(_batchNumber);
                }

                bytes32 correctBatchRoot = s.l2LogsRootHashes[_batchNumber];
                if (correctBatchRoot == bytes32(0)) {
                    revert LocalRootIsZero();
                }
                return correctBatchRoot == batchSettlementRoot;
            }

            if (s.l2LogsRootHashes[_batchNumber] != bytes32(0)) {
                revert LocalRootMustBeZero();
            }

            // Now, we'll have to check that the Gateway included the message.
            bytes32 batchLeafHash = MessageHashing.batchLeafHash(batchSettlementRoot, _batchNumber);

            uint256 batchLeafProofMask = uint256(bytes32(_proof[ptr]));
            ++ptr;

            bytes32 chainIdRoot = Merkle.calculateRootMemory(
                extractSlice(_proof, ptr, ptr + batchLeafProofLen),
                batchLeafProofMask,
                batchLeafHash
            );
            ptr += batchLeafProofLen;

            chainIdLeaf = MessageHashing.chainIdLeafHash(chainIdRoot, s.chainId);
        }

        uint256 settlementLayerBatchNumber;
        uint256 settlementLayerBatchRootMask;
        address settlementLayerAddress;

        // Preventing stack too deep error
        {
            // Now, we just need to double check whether this chainId leaf was present in the tree.
            uint256 settlementLayerPackedBatchInfo = uint256(_proof[ptr]);
            ++ptr;
            settlementLayerBatchNumber = uint256(settlementLayerPackedBatchInfo >> 128);
            settlementLayerBatchRootMask = uint256(settlementLayerPackedBatchInfo & ((1 << 128) - 1));

            uint256 settlementLayerChainId = uint256(_proof[ptr]);
            ++ptr;

            // Assuming that `settlementLayerChainId` is an honest chain, the `chainIdLeaf` should belong
            // to a chain's message root only if the chain has indeed executed its batch on top of it.
            //
            // We trust all chains whitelisted by the Bridgehub governance.
            if (!IBridgehub(s.bridgehub).whitelistedSettlementLayers(settlementLayerChainId)) {
                revert NotSettlementLayer();
            }

            settlementLayerAddress = IBridgehub(s.bridgehub).getZKChain(settlementLayerChainId);
        }

        return
            IMailbox(settlementLayerAddress).proveL2LeafInclusion(
                settlementLayerBatchNumber,
                settlementLayerBatchRootMask,
                chainIdLeaf,
                extractSliceUntilEnd(_proof, ptr)
            );
    }

    /// @dev Prove that a specific L2 log was sent in a specific L2 batch number
    function _proveL2LogInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) internal view returns (bool) {
        bytes32 hashedLog = keccak256(
            // solhint-disable-next-line func-named-parameters
            abi.encodePacked(_log.l2ShardId, _log.isService, _log.txNumberInBatch, _log.sender, _log.key, _log.value)
        );
        // Check that hashed log is not the default one,
        // otherwise it means that the value is out of range of sent L2 -> L1 logs
        if (hashedLog == L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH) {
            revert HashedLogIsDefault();
        }

        // It is ok to not check length of `_proof` array, as length
        // of leaf preimage (which is `L2_TO_L1_LOG_SERIALIZE_SIZE`) is not
        // equal to the length of other nodes preimages (which are `2 * 32`)

        // We can use `index` as a mask, since the `localMessageRoot` is on the left part of the tree.

        return _proveL2LeafInclusion(_batchNumber, _index, hashedLog, _proof);
    }

    /// @dev Convert arbitrary-length message to the raw l2 log
    function _L2MessageToLog(L2Message calldata _message) internal pure returns (L2Log memory) {
        return
            L2Log({
                l2ShardId: 0,
                isService: true,
                txNumberInBatch: _message.txNumberInBatch,
                sender: address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
                key: bytes32(uint256(uint160(_message.sender))),
                value: keccak256(_message.data)
            });
    }

    /// @inheritdoc IMailbox
    function l2TransactionBaseCost(
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) public view returns (uint256) {
        uint256 l2GasPrice = _deriveL2GasPrice(_gasPrice, _l2GasPerPubdataByteLimit);
        return l2GasPrice * _l2GasLimit;
    }

    /// @notice Derives the price for L2 gas in base token to be paid.
    /// @param _l1GasPrice The gas price on L1
    /// @param _gasPerPubdata The price for each pubdata byte in L2 gas
    /// @return The price of L2 gas in the base token
    function _deriveL2GasPrice(uint256 _l1GasPrice, uint256 _gasPerPubdata) internal view returns (uint256) {
        FeeParams memory feeParams = s.feeParams;
        if (s.baseTokenGasPriceMultiplierDenominator == 0) {
            revert BaseTokenGasPriceDenominatorNotSet();
        }
        uint256 l1GasPriceConverted = (_l1GasPrice * s.baseTokenGasPriceMultiplierNominator) /
            s.baseTokenGasPriceMultiplierDenominator;
        uint256 pubdataPriceBaseToken;
        if (feeParams.pubdataPricingMode == PubdataPricingMode.Rollup) {
            // slither-disable-next-line divide-before-multiply
            pubdataPriceBaseToken = L1_GAS_PER_PUBDATA_BYTE * l1GasPriceConverted;
        }

        // slither-disable-next-line divide-before-multiply
        uint256 batchOverheadBaseToken = uint256(feeParams.batchOverheadL1Gas) * l1GasPriceConverted;
        uint256 fullPubdataPriceBaseToken = pubdataPriceBaseToken +
            batchOverheadBaseToken /
            uint256(feeParams.maxPubdataPerBatch);

        uint256 l2GasPrice = feeParams.minimalL2GasPrice + batchOverheadBaseToken / uint256(feeParams.maxL2GasPerBatch);
        uint256 minL2GasPriceBaseToken = (fullPubdataPriceBaseToken + _gasPerPubdata - 1) / _gasPerPubdata;

        return Math.max(l2GasPrice, minL2GasPriceBaseToken);
    }

    /// @inheritdoc IMailbox
    function requestL2TransactionToGatewayMailbox(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) external override onlyL1 returns (bytes32 canonicalTxHash) {
        if (!IBridgehub(s.bridgehub).whitelistedSettlementLayers(s.chainId)) {
            revert NotSettlementLayer();
        }
        if (IChainTypeManager(s.chainTypeManager).getZKChain(_chainId) != msg.sender) {
            revert NotHyperchain();
        }

        BridgehubL2TransactionRequest memory wrappedRequest = _wrapRequest({
            _chainId: _chainId,
            _canonicalTxHash: _canonicalTxHash,
            _expirationTimestamp: _expirationTimestamp
        });
        canonicalTxHash = _requestL2TransactionFree(wrappedRequest);
    }

    /// @inheritdoc IMailbox
    function bridgehubRequestL2TransactionOnGateway(
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) external override onlyBridgehub {
        _writePriorityOpHash(_canonicalTxHash, _expirationTimestamp);
        emit NewRelayedPriorityTransaction(_getTotalPriorityTxs(), _canonicalTxHash, _expirationTimestamp);
    }

    function _wrapRequest(
        uint256 _chainId,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) internal view returns (BridgehubL2TransactionRequest memory) {
        // solhint-disable-next-line func-named-parameters
        bytes memory data = abi.encodeCall(
            IBridgehub.forwardTransactionOnGateway,
            (_chainId, _canonicalTxHash, _expirationTimestamp)
        );
        return
            BridgehubL2TransactionRequest({
                /// There is no sender for the wrapping, we use a virtual address.
                sender: SETTLEMENT_LAYER_RELAY_SENDER,
                contractL2: L2_BRIDGEHUB_ADDR,
                mintValue: 0,
                l2Value: 0,
                // Very large amount
                l2GasLimit: 72_000_000,
                l2Calldata: data,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                factoryDeps: new bytes[](0),
                // Tx is free, no so refund recipient needed
                refundRecipient: address(0)
            });
    }

    ///  @inheritdoc IMailbox
    function requestL2ServiceTransaction(
        address _contractL2,
        bytes calldata _l2Calldata
    ) external onlySelf returns (bytes32 canonicalTxHash) {
        canonicalTxHash = _requestL2TransactionFree(
            BridgehubL2TransactionRequest({
                sender: SERVICE_TRANSACTION_SENDER,
                contractL2: _contractL2,
                mintValue: 0,
                l2Value: 0,
                // Very large amount
                l2GasLimit: 72_000_000,
                l2Calldata: _l2Calldata,
                l2GasPerPubdataByteLimit: REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                factoryDeps: new bytes[](0),
                // Tx is free, so no refund recipient needed
                refundRecipient: address(0)
            })
        );

        if (s.settlementLayer != address(0)) {
            // slither-disable-next-line unused-return
            IMailbox(s.settlementLayer).requestL2TransactionToGatewayMailbox({
                _chainId: s.chainId,
                _canonicalTxHash: canonicalTxHash,
                _expirationTimestamp: uint64(block.timestamp + PRIORITY_EXPIRATION)
            });
        }
    }

    function _requestL2TransactionSender(
        BridgehubL2TransactionRequest memory _request
    ) internal nonReentrant returns (bytes32 canonicalTxHash) {
        // Check that the transaction is allowed by the filterer (if the filterer is set).
        if (s.transactionFilterer != address(0)) {
            if (
                !ITransactionFilterer(s.transactionFilterer).isTransactionAllowed({
                    sender: _request.sender,
                    contractL2: _request.contractL2,
                    mintValue: _request.mintValue,
                    l2Value: _request.l2Value,
                    l2Calldata: _request.l2Calldata,
                    refundRecipient: _request.refundRecipient
                })
            ) {
                revert TransactionNotAllowed();
            }
        }

        // Enforcing that `_request.l2GasPerPubdataByteLimit` equals to a certain constant number. This is needed
        // to ensure that users do not get used to using "exotic" numbers for _request.l2GasPerPubdataByteLimit, e.g. 1-2, etc.
        // VERY IMPORTANT: nobody should rely on this constant to be fixed and every contract should give their users the ability to provide the
        // ability to provide `_request.l2GasPerPubdataByteLimit` for each independent transaction.
        // CHANGING THIS CONSTANT SHOULD BE A CLIENT-SIDE CHANGE.
        if (_request.l2GasPerPubdataByteLimit != REQUIRED_L2_GAS_PRICE_PER_PUBDATA) {
            revert GasPerPubdataMismatch();
        }

        WritePriorityOpParams memory params;
        params.request = _request;

        canonicalTxHash = _requestL2Transaction(params);
    }

    function _requestL2Transaction(WritePriorityOpParams memory _params) internal returns (bytes32 canonicalTxHash) {
        BridgehubL2TransactionRequest memory request = _params.request;

        if (request.factoryDeps.length > MAX_NEW_FACTORY_DEPS) {
            revert TooManyFactoryDeps();
        }
        _params.txId = _nextPriorityTxId();

        // Checking that the user provided enough ether to pay for the transaction.
        _params.l2GasPrice = _deriveL2GasPrice(tx.gasprice, request.l2GasPerPubdataByteLimit);
        uint256 baseCost = _params.l2GasPrice * request.l2GasLimit;
        if (request.mintValue < baseCost + request.l2Value) {
            revert MsgValueTooLow(baseCost + request.l2Value, request.mintValue);
        }

        request.refundRecipient = AddressAliasHelper.actualRefundRecipient(request.refundRecipient, request.sender);
        // Change the sender address if it is a smart contract to prevent address collision between L1 and L2.
        // Please note, currently ZKsync address derivation is different from Ethereum one, but it may be changed in the future.
        // solhint-disable avoid-tx-origin
        // slither-disable-next-line tx-origin
        if (request.sender != tx.origin) {
            request.sender = AddressAliasHelper.applyL1ToL2Alias(request.sender);
        }

        // populate missing fields
        _params.expirationTimestamp = uint64(block.timestamp + PRIORITY_EXPIRATION); // Safe to cast

        L2CanonicalTransaction memory transaction;
        (transaction, canonicalTxHash) = _validateTx(_params);

        _writePriorityOp(transaction, _params.request.factoryDeps, canonicalTxHash, _params.expirationTimestamp);
        if (s.settlementLayer != address(0)) {
            // slither-disable-next-line unused-return
            IMailbox(s.settlementLayer).requestL2TransactionToGatewayMailbox({
                _chainId: s.chainId,
                _canonicalTxHash: canonicalTxHash,
                _expirationTimestamp: _params.expirationTimestamp
            });
        }
    }

    function _nextPriorityTxId() internal view returns (uint256) {
        if (_isPriorityQueueActive()) {
            return s.priorityQueue.getTotalPriorityTxs();
        } else {
            return s.priorityTree.getTotalPriorityTxs();
        }
    }

    function _requestL2TransactionFree(
        BridgehubL2TransactionRequest memory _request
    ) internal nonReentrant returns (bytes32 canonicalTxHash) {
        WritePriorityOpParams memory params = WritePriorityOpParams({
            request: _request,
            txId: _nextPriorityTxId(),
            l2GasPrice: 0,
            expirationTimestamp: uint64(block.timestamp + PRIORITY_EXPIRATION)
        });

        L2CanonicalTransaction memory transaction;
        (transaction, canonicalTxHash) = _validateTx(params);
        _writePriorityOp(transaction, params.request.factoryDeps, canonicalTxHash, params.expirationTimestamp);
    }

    function _serializeL2Transaction(
        WritePriorityOpParams memory _priorityOpParams
    ) internal pure returns (L2CanonicalTransaction memory transaction) {
        BridgehubL2TransactionRequest memory request = _priorityOpParams.request;
        transaction = L2CanonicalTransaction({
            txType: PRIORITY_OPERATION_L2_TX_TYPE,
            from: uint256(uint160(request.sender)),
            to: uint256(uint160(request.contractL2)),
            gasLimit: request.l2GasLimit,
            gasPerPubdataByteLimit: request.l2GasPerPubdataByteLimit,
            maxFeePerGas: uint256(_priorityOpParams.l2GasPrice),
            maxPriorityFeePerGas: uint256(0),
            paymaster: uint256(0),
            // Note, that the priority operation id is used as "nonce" for L1->L2 transactions
            nonce: uint256(_priorityOpParams.txId),
            value: request.l2Value,
            reserved: [request.mintValue, uint256(uint160(request.refundRecipient)), 0, 0],
            data: request.l2Calldata,
            signature: new bytes(0),
            factoryDeps: _hashFactoryDeps(request.factoryDeps),
            paymasterInput: new bytes(0),
            reservedDynamic: new bytes(0)
        });
    }

    function _validateTx(
        WritePriorityOpParams memory _priorityOpParams
    ) internal view returns (L2CanonicalTransaction memory transaction, bytes32 canonicalTxHash) {
        transaction = _serializeL2Transaction(_priorityOpParams);
        bytes memory transactionEncoding = abi.encode(transaction);
        TransactionValidator.validateL1ToL2Transaction(
            transaction,
            transactionEncoding,
            s.priorityTxMaxGasLimit,
            s.feeParams.priorityTxMaxPubdata
        );
        canonicalTxHash = keccak256(transactionEncoding);
    }

    /// @notice Stores a transaction record in storage & send event about that
    function _writePriorityOp(
        L2CanonicalTransaction memory _transaction,
        bytes[] memory _factoryDeps,
        bytes32 _canonicalTxHash,
        uint64 _expirationTimestamp
    ) internal {
        _writePriorityOpHash(_canonicalTxHash, _expirationTimestamp);

        // Data that is needed for the operator to simulate priority queue offchain
        // solhint-disable-next-line func-named-parameters
        emit NewPriorityRequest(_transaction.nonce, _canonicalTxHash, _expirationTimestamp, _transaction, _factoryDeps);
    }

    function _writePriorityOpHash(bytes32 _canonicalTxHash, uint64 _expirationTimestamp) internal {
        if (_isPriorityQueueActive()) {
            s.priorityQueue.pushBack(
                PriorityOperation({
                    canonicalTxHash: _canonicalTxHash,
                    expirationTimestamp: _expirationTimestamp,
                    layer2Tip: uint192(0) // TODO: Restore after fee modeling will be stable. (SMA-1230)
                })
            );
        }
        s.priorityTree.push(_canonicalTxHash);
    }

    /// @notice Hashes the L2 bytecodes and returns them in the format in which they are processed by the bootloader
    function _hashFactoryDeps(bytes[] memory _factoryDeps) internal pure returns (uint256[] memory hashedFactoryDeps) {
        uint256 factoryDepsLen = _factoryDeps.length;
        hashedFactoryDeps = new uint256[](factoryDepsLen);
        for (uint256 i = 0; i < factoryDepsLen; i = i.uncheckedInc()) {
            bytes32 hashedBytecode = L2ContractHelper.hashL2Bytecode(_factoryDeps[i]);

            // Store the resulting hash sequentially in bytes.
            assembly {
                mstore(add(hashedFactoryDeps, mul(add(i, 1), 32)), hashedBytecode)
            }
        }
    }

    ///////////////////////////////////////////////////////
    //////// Legacy Era functions

    /// @inheritdoc IMailbox
    function finalizeEthWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external nonReentrant onlyL1 {
        if (s.chainId != ERA_CHAIN_ID) {
            revert OnlyEraSupported();
        }
        address sharedBridge = IBridgehub(s.bridgehub).sharedBridge();
        IL1AssetRouter(sharedBridge).finalizeWithdrawal({
            _chainId: ERA_CHAIN_ID,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _message: _message,
            _merkleProof: _merkleProof
        });
    }

    ///  @inheritdoc IMailbox
    function requestL2Transaction(
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) external payable onlyL1 returns (bytes32 canonicalTxHash) {
        if (s.chainId != ERA_CHAIN_ID) {
            revert OnlyEraSupported();
        }
        canonicalTxHash = _requestL2TransactionSender(
            BridgehubL2TransactionRequest({
                sender: msg.sender,
                contractL2: _contractL2,
                mintValue: msg.value,
                l2Value: _l2Value,
                l2GasLimit: _l2GasLimit,
                l2Calldata: _calldata,
                l2GasPerPubdataByteLimit: _l2GasPerPubdataByteLimit,
                factoryDeps: _factoryDeps,
                refundRecipient: _refundRecipient
            })
        );
        address sharedBridge = IBridgehub(s.bridgehub).sharedBridge();
        IL1AssetRouter(sharedBridge).bridgehubDepositBaseToken{value: msg.value}(
            s.chainId,
            s.baseTokenAssetId,
            msg.sender,
            msg.value
        );
    }
}
