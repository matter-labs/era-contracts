// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "@openzeppelin/contracts/utils/math/Math.sol";

import "../interfaces/IMailbox.sol";
import "../libraries/Merkle.sol";
import "../libraries/PriorityQueue.sol";
import "../Storage.sol";
import "../Config.sol";
import "../../common/libraries/UncheckedMath.sol";
import "../../common/libraries/UnsafeBytes.sol";
import "../../common/libraries/L2ContractHelper.sol";
import "../../common/L2ContractAddresses.sol";
import "../../vendor/AddressAliasHelper.sol";
import "./Base.sol";

/// @title zkSync Mailbox contract providing interfaces for L1 <-> L2 interaction.
/// @author Matter Labs
contract MailboxFacet is Base, IMailbox {
    using UncheckedMath for uint256;
    using PriorityQueue for PriorityQueue.Queue;

    /// @notice Prove that a specific arbitrary-length message was sent in a specific L2 block number
    /// @param _blockNumber The executed L2 block number in which the message appeared
    /// @param _index The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _message Information about the sent message: sender address, the message itself, tx index in the L2 block where the message was sent
    /// @param _proof Merkle proof for inclusion of L2 log that was sent with the message
    /// @return Whether the proof is valid
    function proveL2MessageInclusion(
        uint256 _blockNumber,
        uint256 _index,
        L2Message memory _message,
        bytes32[] calldata _proof
    ) public view returns (bool) {
        return _proveL2LogInclusion(_blockNumber, _index, _L2MessageToLog(_message), _proof);
    }

    /// @notice Prove that a specific L2 log was sent in a specific L2 block
    /// @param _blockNumber The executed L2 block number in which the log appeared
    /// @param _index The position of the l2log in the L2 logs Merkle tree
    /// @param _log Information about the sent log
    /// @param _proof Merkle proof for inclusion of the L2 log
    /// @return Whether the proof is correct and L2 log is included in block
    function proveL2LogInclusion(
        uint256 _blockNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) external view returns (bool) {
        return _proveL2LogInclusion(_blockNumber, _index, _log, _proof);
    }

    /// @notice Prove that the L1 -> L2 transaction was processed with the specified status.
    /// @param _l2TxHash The L2 canonical transaction hash
    /// @param _l2BlockNumber The L2 block number where the transaction was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBlock The L2 transaction number in a block, in which the log was sent
    /// @param _merkleProof The Merkle proof of the processing L1 -> L2 transaction
    /// @param _status The execution status of the L1 -> L2 transaction (true - success & 0 - fail)
    /// @return Whether the proof is correct and the transaction was actually executed with provided status
    /// NOTE: It may return `false` for incorrect proof, but it doesn't mean that the L1 -> L2 transaction has an opposite status!
    function proveL1ToL2TransactionStatus(
        bytes32 _l2TxHash,
        uint256 _l2BlockNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBlock,
        bytes32[] calldata _merkleProof,
        TxStatus _status
    ) public view override returns (bool) {
        // Bootloader sends an L2 -> L1 log only after processing the L1 -> L2 transaction.
        // Thus, we can verify that the L1 -> L2 transaction was included in the L2 block with specified status.
        //
        // The semantics of such L2 -> L1 log is always:
        // - sender = L2_BOOTLOADER_ADDRESS
        // - key = hash(L1ToL2Transaction)
        // - value = status of the processing transaction (1 - success & 0 - fail)
        // - isService = true (just a conventional value)
        // - l2ShardId = 0 (means that L1 -> L2 transaction was processed in a rollup shard, other shards are not available yet anyway)
        // - txNumberInBlock = number of transaction in the block
        L2Log memory l2Log = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBlock: _l2TxNumberInBlock,
            sender: L2_BOOTLOADER_ADDRESS,
            key: _l2TxHash,
            value: bytes32(uint256(_status))
        });
        return _proveL2LogInclusion(_l2BlockNumber, _l2MessageIndex, l2Log, _merkleProof);
    }

    /// @notice Transfer ether from the contract to the receiver
    /// @dev Reverts only if the transfer call failed
    function _withdrawFunds(address _to, uint256 _amount) internal {
        bool callSuccess;
        // Low-level assembly call, to avoid any memory copying (save gas)
        assembly {
            callSuccess := call(gas(), _to, _amount, 0, 0, 0, 0)
        }
        require(callSuccess, "pz");
    }

    /// @dev Prove that a specific L2 log was sent in a specific L2 block number
    function _proveL2LogInclusion(
        uint256 _blockNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] calldata _proof
    ) internal view returns (bool) {
        require(_blockNumber <= s.totalBlocksExecuted, "xx");

        bytes32 hashedLog = keccak256(
            abi.encodePacked(_log.l2ShardId, _log.isService, _log.txNumberInBlock, _log.sender, _log.key, _log.value)
        );
        // Check that hashed log is not the default one,
        // otherwise it means that the value is out of range of sent L2 -> L1 logs
        require(hashedLog != L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, "tw");
        // Check that the proof length is exactly the same as tree height, to prevent
        // any shorter/longer paths attack on the Merkle path validation
        require(_proof.length == L2_TO_L1_LOG_MERKLE_TREE_HEIGHT, "rz");

        bytes32 calculatedRootHash = Merkle.calculateRoot(_proof, _index, hashedLog);
        bytes32 actualRootHash = s.l2LogsRootHashes[_blockNumber];

        return actualRootHash == calculatedRootHash;
    }

    /// @dev Convert arbitrary-length message to the raw l2 log
    function _L2MessageToLog(L2Message memory _message) internal pure returns (L2Log memory) {
        return
            L2Log({
                l2ShardId: 0,
                isService: true,
                txNumberInBlock: _message.txNumberInBlock,
                sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
                key: bytes32(uint256(uint160(_message.sender))),
                value: keccak256(_message.data)
            });
    }

    /// @notice Estimates the cost in Ether of requesting execution of an L2 transaction from L1
    /// @return The estimated L2 gas for the transaction to be paid
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
    function _deriveL2GasPrice(uint256 _l1GasPrice, uint256 _gasPricePerPubdata) internal pure returns (uint256) {
        uint256 pubdataPriceETH = L1_GAS_PER_PUBDATA_BYTE * _l1GasPrice;
        uint256 minL2GasPriceETH = (pubdataPriceETH + _gasPricePerPubdata - 1) / _gasPricePerPubdata;

        return Math.max(FAIR_L2_GAS_PRICE, minL2GasPriceETH);
    }

    /// @notice Finalize the withdrawal and release funds
    /// @param _l2BlockNumber The L2 block number where the withdrawal was processed
    /// @param _l2MessageIndex The position in the L2 logs Merkle tree of the l2Log that was sent with the message
    /// @param _l2TxNumberInBlock The L2 transaction number in a block, in which the log was sent
    /// @param _message The L2 withdraw data, stored in an L2 -> L1 message
    /// @param _merkleProof The Merkle proof of the inclusion L2 -> L1 message about withdrawal initialization
    function finalizeEthWithdrawal(
        uint256 _l2BlockNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBlock,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external override nonReentrant senderCanCallFunction(s.allowList) {
        require(!s.isEthWithdrawalFinalized[_l2BlockNumber][_l2MessageIndex], "jj");

        L2Message memory l2ToL1Message = L2Message({
            txNumberInBlock: _l2TxNumberInBlock,
            sender: L2_ETH_TOKEN_SYSTEM_CONTRACT_ADDR,
            data: _message
        });

        (address _l1WithdrawReceiver, uint256 _amount) = _parseL2WithdrawalMessage(_message);

        bool proofValid = proveL2MessageInclusion(_l2BlockNumber, _l2MessageIndex, l2ToL1Message, _merkleProof);
        require(proofValid, "pi"); // Failed to verify that withdrawal was actually initialized on L2

        s.isEthWithdrawalFinalized[_l2BlockNumber][_l2MessageIndex] = true;
        _withdrawFunds(_l1WithdrawReceiver, _amount);

        emit EthWithdrawalFinalized(_l1WithdrawReceiver, _amount);
    }

    /// @notice Request execution of L2 transaction from L1.
    /// @param _contractL2 The L2 receiver address
    /// @param _l2Value `msg.value` of L2 transaction
    /// @param _calldata The input of the L2 transaction
    /// @param _l2GasLimit Maximum amount of L2 gas that transaction can consume during execution on L2
    /// @param _l2GasPerPubdataByteLimit The maximum amount L2 gas that the operator may charge the user for single byte of pubdata.
    /// @param _factoryDeps An array of L2 bytecodes that will be marked as known on L2
    /// @param _refundRecipient The address on L2 that will receive the refund for the transaction. If the transaction fails,
    /// it will also be the address to receive `_l2Value`.
    /// @return canonicalTxHash The hash of the requested L2 transaction. This hash can be used to follow the transaction status
    function requestL2Transaction(
        address _contractL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        address _refundRecipient
    ) external payable nonReentrant senderCanCallFunction(s.allowList) returns (bytes32 canonicalTxHash) {
        // Change the sender address if it is a smart contract to prevent address collision between L1 and L2.
        // Please note, currently zkSync address derivation is different from Ethereum one, but it may be changed in the future.
        address sender = msg.sender;
        if (sender != tx.origin) {
            sender = AddressAliasHelper.applyL1ToL2Alias(msg.sender);
        }

        // Enforcing that `_l2GasPerPubdataByteLimit` equals to a certain constant number. This is needed
        // to ensure that users do not get used to using "exotic" numbers for _l2GasPerPubdataByteLimit, e.g. 1-2, etc.
        // VERY IMPORTANT: nobody should rely on this constant to be fixed and every contract should give their users the ability to provide the
        // ability to provide `_l2GasPerPubdataByteLimit` for each independent transaction.
        // CHANGING THIS CONSTANT SHOULD BE A CLIENT-SIDE CHANGE.
        require(_l2GasPerPubdataByteLimit == REQUIRED_L2_GAS_PRICE_PER_PUBDATA, "qp");

        // The L1 -> L2 transaction may be failed and funds will be sent to the `_refundRecipient`,
        // so we use `msg.value` instead of `_l2Value` as the bridged amount.
        _verifyDepositLimit(msg.sender, msg.value);
        canonicalTxHash = _requestL2Transaction(
            sender,
            _contractL2,
            _l2Value,
            _calldata,
            _l2GasLimit,
            _l2GasPerPubdataByteLimit,
            _factoryDeps,
            false,
            _refundRecipient
        );
    }

    function _verifyDepositLimit(address _depositor, uint256 _amount) internal {
        IAllowList.Deposit memory limitData = IAllowList(s.allowList).getTokenDepositLimitData(address(0)); // address(0) denotes the ETH
        if (!limitData.depositLimitation) return; // no deposit limitation is placed for ETH

        require(s.totalDepositedAmountPerUser[_depositor] + _amount <= limitData.depositCap, "d2");
        s.totalDepositedAmountPerUser[_depositor] += _amount;
    }

    function _requestL2Transaction(
        address _sender,
        address _contractAddressL2,
        uint256 _l2Value,
        bytes calldata _calldata,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        bytes[] calldata _factoryDeps,
        bool _isFree,
        address _refundRecipient
    ) internal returns (bytes32 canonicalTxHash) {
        require(_factoryDeps.length <= MAX_NEW_FACTORY_DEPS, "uj");
        uint64 expirationTimestamp = uint64(block.timestamp + PRIORITY_EXPIRATION); // Safe to cast
        uint256 txId = s.priorityQueue.getTotalPriorityTxs();

        // Here we manually assign fields for the struct to prevent "stack too deep" error
        WritePriorityOpParams memory params;

        // Checking that the user provided enough ether to pay for the transaction.
        // Using a new scope to prevent "stack too deep" error
        {
            params.l2GasPrice = _isFree ? 0 : _deriveL2GasPrice(tx.gasprice, _l2GasPerPubdataByteLimit);
            uint256 baseCost = params.l2GasPrice * _l2GasLimit;
            require(msg.value >= baseCost + _l2Value, "mv"); // The `msg.value` doesn't cover the transaction cost
        }

        // If the `_refundRecipient` is not provided, we use the `_sender` as the recipient.
        address refundRecipient = _refundRecipient == address(0) ? _sender : _refundRecipient;
        // If the `_refundRecipient` is a smart contract, we apply the L1 to L2 alias to prevent foot guns.
        if (refundRecipient.code.length > 0) {
            refundRecipient = AddressAliasHelper.applyL1ToL2Alias(refundRecipient);
        }

        params.sender = _sender;
        params.txId = txId;
        params.l2Value = _l2Value;
        params.contractAddressL2 = _contractAddressL2;
        params.expirationTimestamp = expirationTimestamp;
        params.l2GasLimit = _l2GasLimit;
        params.l2GasPricePerPubdata = _l2GasPerPubdataByteLimit;
        params.valueToMint = msg.value;
        params.refundRecipient = refundRecipient;

        canonicalTxHash = _writePriorityOp(params, _calldata, _factoryDeps);
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

        uint256 l2GasForTxBody = _getTransactionBodyGasLimit(
            _priorityOpParams.l2GasLimit,
            _priorityOpParams.l2GasPricePerPubdata,
            transactionEncoding.length
        );

        // Ensuring that the transaction is provable
        require(l2GasForTxBody <= s.priorityTxMaxGasLimit, "ui");
        // Ensuring that the transaction can not output more pubdata than is processable
        require(l2GasForTxBody / _priorityOpParams.l2GasPricePerPubdata <= PRIORITY_TX_MAX_PUBDATA, "uk");

        // Ensuring that the transaction covers the minimal costs for its processing:
        // hashing its content, publishing the factory dependencies, etc.
        require(
            _getMinimalPriorityTransactionGasLimit(
                transactionEncoding.length,
                _factoryDeps.length,
                _priorityOpParams.l2GasPricePerPubdata
            ) <= _priorityOpParams.l2GasLimit,
            "um"
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
        emit NewPriorityRequest(
            _priorityOpParams.txId,
            canonicalTxHash,
            _priorityOpParams.expirationTimestamp,
            transaction,
            _factoryDeps
        );
    }

    /// @dev Calculates the approximate minimum gas limit required for executing a priority transaction.
    /// @param _encodingLength The length of the priority transaction encoding in bytes.
    /// @param _numberOfFactoryDependencies The number of new factory dependencies that will be added.
    /// @param _l2GasPricePerPubdata The L2 gas price for publishing the priority transaction on L2.
    /// @return The minimum gas limit required to execute the priority transaction.
    /// Note: The calculation includes the main cost of the priority transaction, however, in reality, the operator can spend a little more gas on overheads.
    function _getMinimalPriorityTransactionGasLimit(
        uint256 _encodingLength,
        uint256 _numberOfFactoryDependencies,
        uint256 _l2GasPricePerPubdata
    ) internal pure returns (uint256) {
        uint256 costForComputation;
        {
            // Adding the intrinsic cost for the transaction, i.e. auxiliary prices which can not be easily accounted for
            costForComputation = L1_TX_INTRINSIC_L2_GAS;

            // Taking into account the hashing costs that depend on the length of the transaction
            // Note that L1_TX_DELTA_544_ENCODING_BYTES is the delta in the price for every 544 bytes of
            // the transaction's encoding. It is taken as LCM between 136 and 32 (the length for each keccak256 round
            // and the size of each new encoding word).
            costForComputation += Math.ceilDiv(_encodingLength * L1_TX_DELTA_544_ENCODING_BYTES, 544);

            // Taking into the account the additional costs of providing new factory dependenies
            costForComputation += _numberOfFactoryDependencies * L1_TX_DELTA_FACTORY_DEPS_L2_GAS;

            // There is a minimal amount of computational L2 gas that the transaction should cover
            costForComputation = Math.max(costForComputation, L1_TX_MIN_L2_GAS_BASE);
        }

        uint256 costForPubdata = 0;
        {
            // Adding the intrinsic cost for the transaction, i.e. auxilary prices which can not be easily accounted for
            costForPubdata = L1_TX_INTRINSIC_PUBDATA * _l2GasPricePerPubdata;

            // Taking into the account the additional costs of providing new factory dependenies
            costForPubdata += _numberOfFactoryDependencies * L1_TX_DELTA_FACTORY_DEPS_PUBDATA * _l2GasPricePerPubdata;
        }

        return costForComputation + costForPubdata;
    }

    /// @notice Hashes the L2 bytecodes and returns them in the format in which they are processed by the bootloader
    function _hashFactoryDeps(bytes[] calldata _factoryDeps)
        internal
        pure
        returns (uint256[] memory hashedFactoryDeps)
    {
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

    /// @notice Based on the total L2 gas limit and several other parameters of the transaction
    /// returns the part of the L2 gas that will be spent on the block's overhead.
    /// @dev The details of how this function works can be checked in the documentation
    /// of the fee model of zkSync. The appropriate comments are also present
    /// in the Rust implementation description of function `get_maximal_allowed_overhead`.
    /// @param _totalGasLimit The L2 gas limit that includes both the overhead for processing the block
    /// and the L2 gas needed to process the transaction itself (i.e. the actual gasLimit that will be used for the transaction).
    function _getOverheadForTransaction(
        uint256 _totalGasLimit,
        uint256 _gasPricePerPubdata,
        uint256 _encodingLength
    ) internal pure returns (uint256 blockOverheadForTransaction) {
        uint256 blockOverheadGas = BLOCK_OVERHEAD_L2_GAS + BLOCK_OVERHEAD_PUBDATA * _gasPricePerPubdata;

        // The overhead from taking up the transaction's slot
        uint256 txSlotOverhead = Math.ceilDiv(blockOverheadGas, MAX_TRANSACTIONS_IN_BLOCK);
        blockOverheadForTransaction = Math.max(blockOverheadForTransaction, txSlotOverhead);

        // The overhead for occupying the bootloader memory can be derived from encoded_len
        uint256 overheadForLength = Math.ceilDiv(_encodingLength * blockOverheadGas, BOOTLOADER_TX_ENCODING_SPACE);
        blockOverheadForTransaction = Math.max(blockOverheadForTransaction, overheadForLength);

        // The overhead for possible published public data
        // TODO: possibly charge a separate fee for possible pubdata spending
        // uint256 overheadForPublicData;
        // {
        //     uint256 numerator = (blockOverheadGas * _totalGasLimit + _gasPricePerPubdata * MAX_PUBDATA_PER_BLOCK);
        //     uint256 denominator = (_gasPricePerPubdata * MAX_PUBDATA_PER_BLOCK + blockOverheadGas);

        //     overheadForPublicData = (numerator - 1) / denominator;
        // }
        // blockOverheadForTransaction = Math.max(blockOverheadForTransaction, overheadForPublicData);

        // The overhead for ergs that could be used to use single-instance circuits
        uint256 overheadForGas;
        {
            uint256 numerator = blockOverheadGas * _totalGasLimit + L2_TX_MAX_GAS_LIMIT;
            uint256 denominator = L2_TX_MAX_GAS_LIMIT + blockOverheadGas;

            overheadForGas = (numerator - 1) / denominator;
        }
        blockOverheadForTransaction = Math.max(blockOverheadForTransaction, overheadForGas);
    }

    /// @notice Based on the full L2 gas limit (that includes the block overhead) and other
    /// properties of the transaction, returns the l2GasLimit for the body of the transaction (the actual execution).
    /// @param _totalGasLimit The L2 gas limit that includes both the overhead for processing the block
    /// and the L2 gas needed to process the transaction itself (i.e. the actual l2GasLimit that will be used for the transaction).
    /// @param _gasPricePerPubdata The L2 gas price for each byte of pubdata.
    /// @param _encodingLength The length of the ABI-encoding of the transaction.
    function _getTransactionBodyGasLimit(
        uint256 _totalGasLimit,
        uint256 _gasPricePerPubdata,
        uint256 _encodingLength
    ) internal pure returns (uint256 txBodyGasLimit) {
        uint256 overhead = _getOverheadForTransaction(_totalGasLimit, _gasPricePerPubdata, _encodingLength);

        require(_totalGasLimit >= overhead, "my"); // provided gas limit doesn't cover transaction overhead
        unchecked {
            // We enforce the fact that `_totalGasLimit >= overhead` explicitly above.
            txBodyGasLimit = _totalGasLimit - overhead;
        }
    }

    /// @dev Decode the withdraw message that came from L2
    function _parseL2WithdrawalMessage(bytes memory _message)
        internal
        pure
        returns (address l1Receiver, uint256 amount)
    {
        // Check that the message length is correct.
        // It should be equal to the length of the function signature + address + uint256 = 4 + 20 + 32 = 56 (bytes).
        require(_message.length == 56);

        (uint32 functionSignature, uint256 offset) = UnsafeBytes.readUint32(_message, 0);
        require(bytes4(functionSignature) == this.finalizeEthWithdrawal.selector);

        (l1Receiver, offset) = UnsafeBytes.readAddress(_message, offset);
        (amount, offset) = UnsafeBytes.readUint256(_message, offset);
    }
}
