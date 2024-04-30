// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMailbox} from "../../chain-interfaces/IMailbox.sol";
import {ITransactionFilterer} from "../../chain-interfaces/ITransactionFilterer.sol";
import {Merkle} from "../../libraries/Merkle.sol";
import {PriorityQueue, PriorityOperation} from "../../libraries/PriorityQueue.sol";
import {TransactionValidator} from "../../libraries/TransactionValidator.sol";
import {WritePriorityOpParams, L2CanonicalTransaction, L2Message, L2Log, TxStatus, BridgehubL2TransactionRequest} from "../../../common/Messaging.sol";
import {FeeParams, PubdataPricingMode} from "../ZkSyncHyperchainStorage.sol";
import {UncheckedMath} from "../../../common/libraries/UncheckedMath.sol";
import {L2ContractHelper} from "../../../common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "../../../vendor/AddressAliasHelper.sol";
import {ZkSyncHyperchainBase} from "./ZkSyncHyperchainBase.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, ETH_TOKEN_ADDRESS, L1_GAS_PER_PUBDATA_BYTE, L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, PRIORITY_OPERATION_L2_TX_TYPE, PRIORITY_EXPIRATION, MAX_NEW_FACTORY_DEPS} from "../../../common/Config.sol";
import {L2_BOOTLOADER_ADDRESS, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../../../common/L2ContractAddresses.sol";

import {IL1SharedBridge} from "../../../bridge/interfaces/IL1SharedBridge.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZkSyncHyperchainBase} from "../../chain-interfaces/IZkSyncHyperchainBase.sol";

/// @title zkSync Mailbox contract providing interfaces for L1 <-> L2 interaction.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract MailboxFacet is ZkSyncHyperchainBase, IMailbox {
    using UncheckedMath for uint256;
    using PriorityQueue for PriorityQueue.Queue;

    /// @inheritdoc IZkSyncHyperchainBase
    string public constant override getName = "MailboxFacet";

    /// @dev Era's chainID
    uint256 immutable ERA_CHAIN_ID;

    constructor(uint256 _eraChainId) {
        ERA_CHAIN_ID = _eraChainId;
    }

    /// @inheritdoc IMailbox
    function transferEthToSharedBridge() external onlyBaseTokenBridge {
        require(s.chainId == ERA_CHAIN_ID, "Mailbox: transferEthToSharedBridge only available for Era on mailbox");

        uint256 amount = address(this).balance;
        address baseTokenBridgeAddress = s.baseTokenBridge;
        IL1SharedBridge(baseTokenBridgeAddress).receiveEth{value: amount}(ERA_CHAIN_ID);
    }

    /// @notice when requesting transactions through the bridgehub
    function bridgehubRequestL2Transaction(
        BridgehubL2TransactionRequest calldata _request
    ) external onlyBridgehub returns (bytes32 canonicalTxHash) {
        canonicalTxHash = _requestL2TransactionSender(_request);
    }

    /// @inheritdoc IMailbox
    function proveL2MessageInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Message memory _message,
        bytes32[] calldata _proof
    ) public view returns (bool) {
        return _proveL2LogInclusion(_batchNumber, _index, _L2MessageToLog(_message), _proof);
    }

    /// @inheritdoc IMailbox
    function proveL2LogInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Log memory _log,
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

    /// @dev Prove that a specific L2 log was sent in a specific L2 batch number
    function _proveL2LogInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) internal view returns (bool) {
        require(_batchNumber <= s.totalBatchesExecuted, "xx");

        bytes32 hashedLog = keccak256(
            // solhint-disable-next-line func-named-parameters
            abi.encodePacked(_log.l2ShardId, _log.isService, _log.txNumberInBatch, _log.sender, _log.key, _log.value)
        );
        // Check that hashed log is not the default one,
        // otherwise it means that the value is out of range of sent L2 -> L1 logs
        require(hashedLog != L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, "tw");

        // It is ok to not check length of `_proof` array, as length
        // of leaf preimage (which is `L2_TO_L1_LOG_SERIALIZE_SIZE`) is not
        // equal to the length of other nodes preimages (which are `2 * 32`)

        bytes32 calculatedRootHash = Merkle.calculateRoot(_proof, _index, hashedLog);
        bytes32 actualRootHash = s.l2LogsRootHashes[_batchNumber];

        return actualRootHash == calculatedRootHash;
    }

    /// @dev Convert arbitrary-length message to the raw l2 log
    function _L2MessageToLog(L2Message memory _message) internal pure returns (L2Log memory) {
        return
            L2Log({
                l2ShardId: 0,
                isService: true,
                txNumberInBatch: _message.txNumberInBatch,
                sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
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
        require(s.baseTokenGasPriceMultiplierDenominator > 0, "Mailbox: baseTokenGasPriceDenominator not set");
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
    function finalizeEthWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external nonReentrant {
        require(s.chainId == ERA_CHAIN_ID, "Mailbox: finalizeEthWithdrawal only available for Era on mailbox");
        IL1SharedBridge(s.baseTokenBridge).finalizeWithdrawal({
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
    ) external payable returns (bytes32 canonicalTxHash) {
        require(s.chainId == ERA_CHAIN_ID, "Mailbox: legacy interface only available for Era");
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
        IL1SharedBridge(s.baseTokenBridge).bridgehubDepositBaseToken{value: msg.value}(
            s.chainId,
            msg.sender,
            ETH_TOKEN_ADDRESS,
            msg.value
        );
    }

    function _requestL2TransactionSender(
        BridgehubL2TransactionRequest memory _request
    ) internal nonReentrant returns (bytes32 canonicalTxHash) {
        // Check that the transaction is allowed by the filterer (if the filterer is set).
        if (s.transactionFilterer != address(0)) {
            require(
                ITransactionFilterer(s.transactionFilterer).isTransactionAllowed({
                    sender: _request.sender,
                    contractL2: _request.contractL2,
                    mintValue: _request.mintValue,
                    l2Value: _request.l2Value,
                    l2Calldata: _request.l2Calldata,
                    refundRecipient: _request.refundRecipient
                }),
                "tf"
            );
        }

        // Enforcing that `_request.l2GasPerPubdataByteLimit` equals to a certain constant number. This is needed
        // to ensure that users do not get used to using "exotic" numbers for _request.l2GasPerPubdataByteLimit, e.g. 1-2, etc.
        // VERY IMPORTANT: nobody should rely on this constant to be fixed and every contract should give their users the ability to provide the
        // ability to provide `_request.l2GasPerPubdataByteLimit` for each independent transaction.
        // CHANGING THIS CONSTANT SHOULD BE A CLIENT-SIDE CHANGE.
        require(_request.l2GasPerPubdataByteLimit == REQUIRED_L2_GAS_PRICE_PER_PUBDATA, "qp");

        WritePriorityOpParams memory params;
        params.request = _request;

        canonicalTxHash = _requestL2Transaction(params);
    }

    function _requestL2Transaction(WritePriorityOpParams memory _params) internal returns (bytes32 canonicalTxHash) {
        BridgehubL2TransactionRequest memory request = _params.request;

        require(request.factoryDeps.length <= MAX_NEW_FACTORY_DEPS, "uj");
        _params.txId = s.priorityQueue.getTotalPriorityTxs();

        // Checking that the user provided enough ether to pay for the transaction.
        _params.l2GasPrice = _deriveL2GasPrice(tx.gasprice, request.l2GasPerPubdataByteLimit);
        uint256 baseCost = _params.l2GasPrice * request.l2GasLimit;
        require(request.mintValue >= baseCost + request.l2Value, "mv"); // The `msg.value` doesn't cover the transaction cost

        request.refundRecipient = AddressAliasHelper.actualRefundRecipient(request.refundRecipient, request.sender);
        // Change the sender address if it is a smart contract to prevent address collision between L1 and L2.
        // Please note, currently zkSync address derivation is different from Ethereum one, but it may be changed in the future.
        // slither-disable-next-line tx-origin
        if (request.sender != tx.origin) {
            request.sender = AddressAliasHelper.applyL1ToL2Alias(request.sender);
        }

        // populate missing fields
        _params.expirationTimestamp = uint64(block.timestamp + PRIORITY_EXPIRATION); // Safe to cast

        canonicalTxHash = _writePriorityOp(_params);
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

    /// @notice Stores a transaction record in storage & send event about that
    function _writePriorityOp(
        WritePriorityOpParams memory _priorityOpParams
    ) internal returns (bytes32 canonicalTxHash) {
        L2CanonicalTransaction memory transaction = _serializeL2Transaction(_priorityOpParams);

        bytes memory transactionEncoding = abi.encode(transaction);

        TransactionValidator.validateL1ToL2Transaction(
            transaction,
            transactionEncoding,
            s.priorityTxMaxGasLimit,
            s.feeParams.priorityTxMaxPubdata
        );

        canonicalTxHash = keccak256(transactionEncoding);

        s.priorityQueue.pushBack(
            PriorityOperation({
                canonicalTxHash: canonicalTxHash,
                expirationTimestamp: _priorityOpParams.expirationTimestamp,
                layer2Tip: uint192(0) // TODO: Restore after fee modeling will be stable. (SMA-1230)
            })
        );

        // Data that is needed for the operator to simulate priority queue offchain
        // solhint-disable-next-line func-named-parameters
        emit NewPriorityRequest(
            _priorityOpParams.txId,
            canonicalTxHash,
            _priorityOpParams.expirationTimestamp,
            transaction,
            _priorityOpParams.request.factoryDeps
        );
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
}
