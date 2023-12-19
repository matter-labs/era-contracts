// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IMailbox, TxStatus} from "../../chain-interfaces/IMailbox.sol";
import {Merkle} from "../../libraries/Merkle.sol";
import {PriorityQueue, PriorityOperation} from "../../libraries/PriorityQueue.sol";
import {TransactionValidator} from "../../libraries/TransactionValidator.sol";
import {L2Message, L2Log, WritePriorityOpParams, L2CanonicalTransaction} from "../../../common/Messaging.sol";
import {UncheckedMath} from "../../../common/libraries/UncheckedMath.sol";
import {UnsafeBytes} from "../../../common/libraries/UnsafeBytes.sol";
import {L2ContractHelper} from "../../../common/libraries/L2ContractHelper.sol";
import {AddressAliasHelper} from "../../../vendor/AddressAliasHelper.sol";
import {StateTransitionChainBase} from "./Base.sol";
import {REQUIRED_L2_GAS_PRICE_PER_PUBDATA, FAIR_L2_GAS_PRICE, L1_GAS_PER_PUBDATA_BYTE, L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, PRIORITY_OPERATION_L2_TX_TYPE, PRIORITY_EXPIRATION, MAX_NEW_FACTORY_DEPS} from "../../../common/Config.sol";
import {L2_BOOTLOADER_ADDRESS, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_ETH_TOKEN_SYSTEM_CONTRACT_ADDR} from "../../../common/L2ContractAddresses.sol";

import {IBridgehub} from "../../../bridgehub/bridgehub-interfaces/IBridgehub.sol";
import {IL1Bridge} from "../../../bridge/interfaces/IL1Bridge.sol";

/// @title zkSync Mailbox contract providing interfaces for L1 <-> L2 interaction.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract MailboxFacet is StateTransitionChainBase, IMailbox {
    using UncheckedMath for uint256;
    using PriorityQueue for PriorityQueue.Queue;

    string public constant override getName = "MailboxFacet";

    /// @dev Era's chainID
    uint256 public immutable eraChainId;

    /// @dev Contract is expected to be used as proxy implementation.
    /// @dev Initialize the implementation to prevent Parity hack.
    constructor(uint256 _eraChainId) reentrancyGuardInitializer {
        eraChainId = _eraChainId;
    }

    // this is implemented in the bridghead, does not go through the router.
    function bridgehubRequestL2Transaction(
        address _sender,
        address _contractL2,
        uint256 _mintValue,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) external payable onlyBridgehub returns (bytes32 canonicalTxHash) {
        canonicalTxHash = _requestL2TransactionSender(
            _sender,
            _contractL2,
            _mintValue,
            _l2Value,
            _calldata,
            _l2GasLimit,
            _l2GasPerPubdataByteLimit,
            _factoryDeps,
            _refundRecipient
        );
    }

    //////////////////

    /// @notice Prove that a specific arbitrary-length message was sent in a specific L2 batch number
    /// @param _batchNumber The executed L2 batch number in which the message appeared
    /// @param _index The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _message Information about the sent message: sender address, the message itself, tx index in the L2 batch where the message was sent
    /// @param _proof Merkle proof for inclusion of L2 log that was sent with the message
    /// @return Whether the proof is valid
    function proveL2MessageInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Message memory _message,
        bytes32[] calldata _proof
    ) public view returns (bool) {
        return _proveL2LogInclusion(_batchNumber, _index, _L2MessageToLog(_message), _proof);
    }

    /// @notice Prove that a specific L2 log was sent in a specific L2 batch
    /// @param _batchNumber The executed L2 batch number in which the log appeared
    /// @param _index The position of the l2log in the L2 logs Merkle tree
    /// @param _log Information about the sent log
    /// @param _proof Merkle proof for inclusion of the L2 log
    /// @return Whether the proof is correct and L2 log is included in batch
    function proveL2LogInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) external view returns (bool) {
        return _proveL2LogInclusion(_batchNumber, _index, _log, _proof);
    }

    /// @notice Prove that the L1 -> L2 transaction was processed with the specified status.
    /// @param _l2TxHash The L2 canonical transaction hash
    /// @param _l2BatchNumber The L2 batch number where the transaction was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in the batch, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction
    /// @param _status The execution status of the L1 -> L2 transaction (true - success & 0 - fail)
    /// @return Whether the proof is correct and the transaction was actually executed with provided status
    /// NOTE: It may return `false` for incorrect proof, but it doesn't mean that the L1 -> L2 transaction has an opposite status!
    function proveL1ToL2TransactionStatus(
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) public view override returns (bool) {
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
        require(_batchNumber <= chainStorage.totalBatchesExecuted, "xx");

        bytes32 hashedLog = keccak256(
            abi.encodePacked(_log.l2ShardId, _log.isService, _log.txNumberInBatch, _log.sender, _log.key, _log.value)
        );
        // Check that hashed log is not the default one,
        // otherwise it means that the value is out of range of sent L2 -> L1 logs
        require(hashedLog != L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, "tw");

        // It is ok to not check length of `_proof` array, as length
        // of leaf preimage (which is `L2_TO_L1_LOG_SERIALIZE_SIZE`) is not
        // equal to the length of other nodes preimages (which are `2 * 32`)

        bytes32 calculatedRootHash = Merkle.calculateRoot(_proof, _index, hashedLog);
        bytes32 actualRootHash = chainStorage.l2LogsRootHashes[_batchNumber];

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

    /// @notice Estimates the cost in Ether of requesting execution of an L2 transaction from L1
    /// @param _gasPrice expected L1 gas price at which the user requests the transaction execution
    /// @param _l2GasLimit Maximum amount of L2 gas that transaction can consume during execution on L2
    /// @param _l2GasPerPubdataByteLimit The maximum amount of L2 gas that the operator may charge the user for a single byte of pubdata.
    /// @return The estimated ETH spent on L2 gas for the transaction
    function l2TransactionBaseCost(
        uint256 _gasPrice,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit
    ) public pure returns (uint256) {
        uint256 l2GasPrice = _deriveL2GasPrice(_gasPrice, _l2GasPerPubdataByteLimit);
        return l2GasPrice * _l2GasLimit;
    }

    /// @notice Derives the price for L2 gas in ETH to be paid.
    /// @param _l1GasPrice The gas price on L1.
    /// @param _gasPricePerPubdata The price for each pubdata byte in L2 gas
    /// @return The price of L2 gas in ETH
    function _deriveL2GasPrice(uint256 _l1GasPrice, uint256 _gasPricePerPubdata) internal pure returns (uint256) {
        uint256 pubdataPriceETH = L1_GAS_PER_PUBDATA_BYTE * _l1GasPrice;
        uint256 minL2GasPriceETH = (pubdataPriceETH + _gasPricePerPubdata - 1) / _gasPricePerPubdata;

        return Math.max(FAIR_L2_GAS_PRICE, minL2GasPriceETH);
    }

    /// @notice Finalize the withdrawal and release funds
    /// here for legacy reasons
    /// @param _l2BatchNumber The L2 batch number where the withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBatch The L2 transaction number in a batch, in which the log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    function finalizeEthWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external override {
        require(chainStorage.chainId != eraChainId, " finalizeEthWithdrawal only available for Era on mailbox");
        IL1Bridge(chainStorage.baseTokenBridge).finalizeWithdrawal(
            eraChainId,
            _l2BatchNumber,
            _l2MessageIndex,
            _l2TxNumberInBatch,
            _message,
            _merkleProof
        );
    }

    // legacy for era
    function requestL2Transaction(
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) external payable returns (bytes32 canonicalTxHash) {
        require(chainStorage.chainId == eraChainId, " requestL2Transaction only available for Era on mailbox");
        canonicalTxHash = _requestL2TransactionSender(
            msg.sender,
            _contractL2,
            msg.value,
            _l2Value,
            _calldata,
            _l2GasLimit,
            _l2GasPerPubdataByteLimit,
            _factoryDeps,
            _refundRecipient
        );
        IL1Bridge(chainStorage.baseTokenBridge).bridgehubDeposit{value: msg.value}(
            chainStorage.chainId,
            address(0),
            msg.value
        );
    }

    /// @notice Request execution of L2 transaction from L1.
    /// @param _contractL2 The L2 receiver address
    /// @param _l2Value `msg.value` of L2 transaction
    /// @param _calldata The input of the L2 transaction
    /// @param _l2GasLimit Maximum amount of L2 gas that transaction can consume during execution on L2
    /// @param _l2GasPerPubdataByteLimit The maximum amount L2 gas that the operator may charge the user for single byte of pubdata.
    /// @param _factoryDeps An array of L2 bytecodes that will be marked as known on L2
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction.
    /// @dev If the L2 deposit finalization transaction fails, the `_refundRecipient` will receive the `_l2Value`.
    /// Please note, the contract may change the refund recipient's address to eliminate sending funds to addresses out of control.
    /// - If `_refundRecipient` is a contract on L1, the refund will be sent to the aliased `_refundRecipient`.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has NO deployed bytecode on L1, the refund will be sent to the `msg.sender` address.
    /// - If `_refundRecipient` is set to `address(0)` and the sender has deployed bytecode on L1, the refund will be sent to the aliased `msg.sender` address.
    /// @dev The address aliasing of L1 contracts as refund recipient on L2 is necessary to guarantee that the funds are controllable,
    /// since address aliasing to the from address for the L2 tx will be applied if the L1 `msg.sender` is a contract.
    /// Without address aliasing for L1 contracts as refund recipients they would not be able to make proper L2 tx requests
    /// through the Mailbox to use or withdraw the funds from L2, and the funds would be lost.
    /// @return canonicalTxHash The hash of the requested L2 transaction. This hash can be used to follow the transaction status
    function _requestL2TransactionSender(
        address _sender,
        address _contractL2,
        uint256 _mintValue,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) internal nonReentrant returns (bytes32 canonicalTxHash) {
        // Change the sender address if it is a smart contract to prevent address collision between L1 and L2.
        // Please note, currently zkSync address derivation is different from Ethereum one, but it may be changed in the future.
        address l2Sender = _sender;
        if (l2Sender != tx.origin) {
            l2Sender = AddressAliasHelper.applyL1ToL2Alias(_sender);
        }

        // Enforcing that `_l2GasPerPubdataByteLimit` equals to a certain constant number. This is needed
        // to ensure that users do not get used to using "exotic" numbers for _l2GasPerPubdataByteLimit, e.g. 1-2, etc.
        // VERY IMPORTANT: nobody should rely on this constant to be fixed and every contract should give their users the ability to provide the
        // ability to provide `_l2GasPerPubdataByteLimit` for each independent transaction.
        // CHANGING THIS CONSTANT SHOULD BE A CLIENT-SIDE CHANGE.
        require(_l2GasPerPubdataByteLimit == REQUIRED_L2_GAS_PRICE_PER_PUBDATA, "qp");

        // Here we manually assign fields for the struct to prevent "stack too deep" error
        WritePriorityOpParams memory params;

        params.sender = l2Sender;
        params.l2Value = _l2Value;
        params.contractAddressL2 = _contractL2;
        params.l2GasLimit = _l2GasLimit;
        params.l2GasPricePerPubdata = _l2GasPerPubdataByteLimit;
        params.refundRecipient = _refundRecipient;

        canonicalTxHash = _requestL2Transaction(_mintValue, params, _calldata, _factoryDeps, false);
    }

    function _requestL2Transaction(
        uint256 _mintValue,
        WritePriorityOpParams memory _params,
        bytes calldata _calldata,
        bytes[] calldata _factoryDeps,
        bool _isFree
    ) internal returns (bytes32 canonicalTxHash) {
        require(_factoryDeps.length <= MAX_NEW_FACTORY_DEPS, "uj");
        _params.txId = chainStorage.priorityQueue.getTotalPriorityTxs();

        // Checking that the user provided enough ether to pay for the transaction.
        // Using a new scope to prevent "stack too deep" error

        _params.l2GasPrice = _isFree ? 0 : _deriveL2GasPrice(tx.gasprice, _params.l2GasPricePerPubdata);
        uint256 baseCost = _params.l2GasPrice * _params.l2GasLimit;
        require(_mintValue >= baseCost + _params.l2Value, "mv"); // The `msg.value` doesn't cover the transaction cost

        // If the `_refundRecipient` is not provided, we use the `_sender` as the recipient.
        address refundRecipient = _params.refundRecipient == address(0) ? _params.sender : _params.refundRecipient;
        // If the `_refundRecipient` is a smart contract, we apply the L1 to L2 alias to prevent foot guns.
        if (refundRecipient.code.length > 0) {
            refundRecipient = AddressAliasHelper.applyL1ToL2Alias(refundRecipient);
        }
        _params.refundRecipient = refundRecipient;

        // populate missing fields
        _params.expirationTimestamp = uint64(block.timestamp + PRIORITY_EXPIRATION); // Safe to cast
        _params.valueToMint = _mintValue;

        canonicalTxHash = _writePriorityOp(_params, _calldata, _factoryDeps);
    }

    function _serializeL2Transaction(
        WritePriorityOpParams memory _priorityOpParams,
        bytes calldata _calldata,
        bytes[] calldata _factoryDeps
    ) internal pure returns (L2CanonicalTransaction memory transaction) {
        transaction = L2CanonicalTransaction({
            txType: PRIORITY_OPERATION_L2_TX_TYPE,
            from: uint256(uint160(_priorityOpParams.sender)),
            to: uint256(uint160(_priorityOpParams.contractAddressL2)),
            gasLimit: _priorityOpParams.l2GasLimit,
            gasPerPubdataByteLimit: _priorityOpParams.l2GasPricePerPubdata,
            maxFeePerGas: uint256(_priorityOpParams.l2GasPrice),
            maxPriorityFeePerGas: uint256(0),
            paymaster: uint256(0),
            // Note, that the priority operation id is used as "nonce" for L1->L2 transactions
            nonce: uint256(_priorityOpParams.txId),
            value: _priorityOpParams.l2Value,
            reserved: [_priorityOpParams.valueToMint, uint256(uint160(_priorityOpParams.refundRecipient)), 0, 0],
            data: _calldata,
            signature: new bytes(0),
            factoryDeps: _hashFactoryDeps(_factoryDeps),
            paymasterInput: new bytes(0),
            reservedDynamic: new bytes(0)
        });
    }

    /// @notice Stores a transaction record in storage & send event about that
    function _writePriorityOp(
        WritePriorityOpParams memory _priorityOpParams,
        bytes calldata _calldata,
        bytes[] calldata _factoryDeps
    ) internal returns (bytes32 canonicalTxHash) {
        L2CanonicalTransaction memory transaction = _serializeL2Transaction(_priorityOpParams, _calldata, _factoryDeps);

        bytes memory transactionEncoding = abi.encode(transaction);

        TransactionValidator.validateL1ToL2Transaction(
            transaction,
            transactionEncoding,
            chainStorage.priorityTxMaxGasLimit
        );

        canonicalTxHash = keccak256(transactionEncoding);

        chainStorage.priorityQueue.pushBack(
            PriorityOperation({
                canonicalTxHash: canonicalTxHash,
                expirationTimestamp: _priorityOpParams.expirationTimestamp,
                layer2Tip: uint192(0) // TODO: Restore after fee modeling will be stable. (SMA-1230)
            })
        );

        // Data that is needed for the operator to simulate priority queue offchain
        emit NewPriorityRequest(
            _priorityOpParams.txId,
            canonicalTxHash,
            _priorityOpParams.expirationTimestamp,
            transaction,
            _factoryDeps
        );
    }

    /// @notice Hashes the L2 bytecodes and returns them in the format in which they are processed by the bootloader
    function _hashFactoryDeps(
        bytes[] calldata _factoryDeps
    ) internal pure returns (uint256[] memory hashedFactoryDeps) {
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
