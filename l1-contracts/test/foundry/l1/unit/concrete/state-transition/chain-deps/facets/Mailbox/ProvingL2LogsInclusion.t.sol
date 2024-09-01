// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {L2Message, L2Log} from "contracts/common/Messaging.sol";
import "forge-std/Test.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, L1_GAS_PER_PUBDATA_BYTE, L2_TO_L1_LOG_SERIALIZE_SIZE} from "contracts/common/Config.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_BOOTLOADER_ADDRESS} from "contracts/common/L2ContractAddresses.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {BatchNotExecuted, HashedLogIsDefault} from "contracts/common/L1ContractErrors.sol";
import {MurkyBase} from "murky/common/MurkyBase.sol";
import {MerkleTest} from "contracts/dev-contracts/test/MerkleTest.sol";
import {TxStatus} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {MerkleTreeNoSort} from "test/foundry/l1/unit/concrete/common/libraries/Merkle/MerkleTreeNoSort.sol";

contract MailboxL2LogsProve is MailboxTest {
    bytes32[] elements;
    MerkleTest merkle;
    MerkleTreeNoSort merkleTree;
    bytes data;
    uint256 batchNumber;
    bool isService;
    uint8 shardId;

    function setUp() public virtual {
        setupDiamondProxy();

        data = abi.encodePacked("test data");
        merkleTree = new MerkleTreeNoSort();
        merkle = new MerkleTest();
        batchNumber = gettersFacet.getTotalBatchesExecuted();
        isService = true;
        shardId = 0;
    }

    function _addHashedLogToMerkleTree(
        uint8 _shardId,
        bool _isService,
        uint16 _txNumberInBatch,
        address _sender,
        bytes32 _key,
        bytes32 _value
    ) internal returns (uint256 index) {
        elements.push(keccak256(abi.encodePacked(_shardId, _isService, _txNumberInBatch, _sender, _key, _value)));

        index = elements.length - 1;
    }

    function test_RevertWhen_batchNumberGreaterThanBatchesExecuted() public {
        L2Message memory message = L2Message({txNumberInBatch: 0, sender: sender, data: data});
        bytes32[] memory proof = _appendProofMetadata(new bytes32[](1));

        _proveL2MessageInclusion({
            _batchNumber: batchNumber + 1,
            _index: 0,
            _message: message,
            _proof: proof,
            _expectedError: abi.encodeWithSelector(BatchNotExecuted.selector, batchNumber + 1)
        });
    }

    function test_success_proveL2MessageInclusion() public {
        uint256 firstLogIndex = _addHashedLogToMerkleTree({
            _shardId: 0,
            _isService: true,
            _txNumberInBatch: 0,
            _sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            _key: bytes32(uint256(uint160(sender))),
            _value: keccak256(data)
        });

        uint256 secondLogIndex = _addHashedLogToMerkleTree({
            _shardId: 0,
            _isService: true,
            _txNumberInBatch: 1,
            _sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            _key: bytes32(uint256(uint160(sender))),
            _value: keccak256(data)
        });

        // Calculate the Merkle root
        bytes32 root = merkleTree.getRoot(elements);
        utilsFacet.util_setL2LogsRootHash(batchNumber, root);

        // Create L2 message
        L2Message memory message = L2Message({txNumberInBatch: 0, sender: sender, data: data});

        // Get Merkle proof for the first element
        bytes32[] memory firstLogProof = merkleTree.getProof(elements, firstLogIndex);

        {
            // Calculate the root using the Merkle proof
            bytes32 leaf = elements[firstLogIndex];
            bytes32 calculatedRoot = merkle.calculateRoot(firstLogProof, firstLogIndex, leaf);

            // Assert that the calculated root matches the expected root
            assertEq(calculatedRoot, root);
        }

        // Prove L2 message inclusion
        bool ret = _proveL2MessageInclusion(batchNumber, firstLogIndex, message, firstLogProof, bytes(""));

        // Assert that the proof was successful
        assertEq(ret, true);

        // Prove L2 message inclusion for wrong leaf
        ret = _proveL2MessageInclusion(batchNumber, secondLogIndex, message, firstLogProof, bytes(""));

        // Assert that the proof has failed
        assertEq(ret, false);
    }

    function test_success_proveL2LogInclusion() public {
        uint256 firstLogIndex = _addHashedLogToMerkleTree({
            _shardId: shardId,
            _isService: isService,
            _txNumberInBatch: 0,
            _sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            _key: bytes32(uint256(uint160(sender))),
            _value: keccak256(data)
        });

        uint256 secondLogIndex = _addHashedLogToMerkleTree({
            _shardId: shardId,
            _isService: isService,
            _txNumberInBatch: 1,
            _sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            _key: bytes32(uint256(uint160(sender))),
            _value: keccak256(data)
        });

        L2Log memory log = L2Log({
            l2ShardId: shardId,
            isService: isService,
            txNumberInBatch: 1,
            sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            key: bytes32(uint256(uint160(sender))),
            value: keccak256(data)
        });

        // Calculate the Merkle root
        bytes32 root = merkleTree.getRoot(elements);
        // Set root hash for current batch
        utilsFacet.util_setL2LogsRootHash(batchNumber, root);

        // Get Merkle proof for the first element
        bytes32[] memory secondLogProof = merkleTree.getProof(elements, secondLogIndex);

        {
            // Calculate the root using the Merkle proof
            bytes32 leaf = elements[secondLogIndex];

            bytes32 calculatedRoot = merkle.calculateRoot(secondLogProof, secondLogIndex, leaf);
            // Assert that the calculated root matches the expected root
            assertEq(calculatedRoot, root);
        }

        // Prove l2 log inclusion with correct proof
        bool ret = _proveL2LogInclusion({
            _batchNumber: batchNumber,
            _index: secondLogIndex,
            _proof: secondLogProof,
            _log: log,
            _expectedError: bytes("")
        });

        // Assert that the proof was successful
        assertEq(ret, true);

        // Prove l2 log inclusion with wrong proof
        ret = _proveL2LogInclusion({
            _batchNumber: batchNumber,
            _index: firstLogIndex,
            _proof: secondLogProof,
            _log: log,
            _expectedError: bytes("")
        });

        // Assert that the proof was successful
        assertEq(ret, false);
    }

    // this is not possible in case of message, because some default values
    // are set during translation from message to log
    function test_RevertWhen_proveL2LogInclusionDefaultLog() public {
        L2Log memory log = L2Log({
            l2ShardId: 0,
            isService: false,
            txNumberInBatch: 0,
            sender: address(0),
            key: bytes32(0),
            value: bytes32(0)
        });

        uint256 firstLogIndex = _addHashedLogToMerkleTree({
            _shardId: 0,
            _isService: true,
            _txNumberInBatch: 1,
            _sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            _key: bytes32(uint256(uint160(sender))),
            _value: keccak256(data)
        });

        // Add first element to the Merkle tree
        elements.push(keccak256(new bytes(L2_TO_L1_LOG_SERIALIZE_SIZE)));
        uint256 secondLogIndex = 1;

        // Calculate the Merkle root
        bytes32 root = merkleTree.getRoot(elements);
        // Set root hash for current batch
        utilsFacet.util_setL2LogsRootHash(batchNumber, root);

        // Get Merkle proof for the first element
        bytes32[] memory secondLogProof = merkleTree.getProof(elements, secondLogIndex);

        {
            // Calculate the root using the Merkle proof
            bytes32 leaf = elements[secondLogIndex];
            bytes32 calculatedRoot = merkle.calculateRoot(secondLogProof, secondLogIndex, leaf);
            // Assert that the calculated root matches the expected root
            assertEq(calculatedRoot, root);
        }

        // Prove log inclusion reverts
        _proveL2LogInclusion(
            batchNumber,
            secondLogIndex,
            log,
            secondLogProof,
            bytes.concat(HashedLogIsDefault.selector)
        );
    }

    function test_success_proveL1ToL2TransactionStatus() public {
        bytes32 firstL2TxHash = keccak256("firstL2Transaction");
        bytes32 secondL2TxHash = keccak256("SecondL2Transaction");
        TxStatus txStatus = TxStatus.Success;

        uint256 firstLogIndex = _addHashedLogToMerkleTree({
            _shardId: shardId,
            _isService: isService,
            _txNumberInBatch: 0,
            _sender: L2_BOOTLOADER_ADDRESS,
            _key: firstL2TxHash,
            _value: bytes32(uint256(txStatus))
        });

        uint256 secondLogIndex = _addHashedLogToMerkleTree({
            _shardId: shardId,
            _isService: isService,
            _txNumberInBatch: 1,
            _sender: L2_BOOTLOADER_ADDRESS,
            _key: secondL2TxHash,
            _value: bytes32(uint256(txStatus))
        });

        // Calculate the Merkle root
        bytes32 root = merkleTree.getRoot(elements);
        // Set root hash for current batch
        utilsFacet.util_setL2LogsRootHash(batchNumber, root);

        // Get Merkle proof for the first element
        bytes32[] memory secondLogProof = merkleTree.getProof(elements, secondLogIndex);

        {
            // Calculate the root using the Merkle proof
            bytes32 leaf = elements[secondLogIndex];
            bytes32 calculatedRoot = merkle.calculateRoot(secondLogProof, secondLogIndex, leaf);
            // Assert that the calculated root matches the expected root
            assertEq(calculatedRoot, root);
        }

        // Prove L1 to L2 transaction status
        bool ret = _proveL1ToL2TransactionStatus({
            _l2TxHash: secondL2TxHash,
            _l2BatchNumber: batchNumber,
            _l2MessageIndex: secondLogIndex,
            _l2TxNumberInBatch: 1,
            _merkleProof: secondLogProof,
            _status: txStatus
        });
        // Assert that the proof was successful
        assertEq(ret, true);
    }

    /// @notice Proves L1 to L2 transaction status and cross-checks new and old encoding
    function _proveL1ToL2TransactionStatus(
        bytes32 _l2TxHash,
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBatch,
        bytes32[] memory _merkleProof,
        TxStatus _status
    ) internal returns (bool) {
        bool retOldEncoding = mailboxFacet.proveL1ToL2TransactionStatus({
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof,
            _status: _status
        });
        bool retNewEncoding = mailboxFacet.proveL1ToL2TransactionStatus({
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _appendProofMetadata(_merkleProof),
            _status: _status
        });

        assertEq(retOldEncoding, retNewEncoding);

        return retOldEncoding;
    }

    /// @notice Proves L2 log inclusion and cross-checks new and old encoding
    function _proveL2LogInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Log memory _log,
        bytes32[] memory _proof,
        bytes memory _expectedError
    ) internal returns (bool) {
        if (_expectedError.length > 0) {
            vm.expectRevert(_expectedError);
        }
        bool retOldEncoding = mailboxFacet.proveL2LogInclusion({
            _batchNumber: _batchNumber,
            _index: _index,
            _proof: _proof,
            _log: _log
        });

        if (_expectedError.length > 0) {
            vm.expectRevert(_expectedError);
        }
        bool retNewEncoding = mailboxFacet.proveL2LogInclusion({
            _batchNumber: _batchNumber,
            _index: _index,
            _proof: _appendProofMetadata(_proof),
            _log: _log
        });

        assertEq(retOldEncoding, retNewEncoding);
        return retOldEncoding;
    }

    function _proveL2MessageInclusion(
        uint256 _batchNumber,
        uint256 _index,
        L2Message memory _message,
        bytes32[] memory _proof,
        bytes memory _expectedError
    ) internal returns (bool) {
        if (_expectedError.length > 0) {
            vm.expectRevert(_expectedError);
        }
        bool retOldEncoding = mailboxFacet.proveL2MessageInclusion({
            _batchNumber: _batchNumber,
            _index: _index,
            _message: _message,
            _proof: _proof
        });

        if (_expectedError.length > 0) {
            vm.expectRevert(_expectedError);
        }
        bool retNewEncoding = mailboxFacet.proveL2MessageInclusion({
            _batchNumber: _batchNumber,
            _index: _index,
            _message: _message,
            _proof: _appendProofMetadata(_proof)
        });

        assertEq(retOldEncoding, retNewEncoding);
        return retOldEncoding;
    }

    /// @notice Appends the proof metadata to the log proof as if the proof is for a batch that settled on L1.
    function _appendProofMetadata(bytes32[] memory logProof) internal returns (bytes32[] memory result) {
        result = new bytes32[](logProof.length + 1);

        result[0] = bytes32(bytes.concat(bytes1(0x01), bytes1(uint8(logProof.length)), bytes30(0x00)));
        for (uint256 i = 0; i < logProof.length; i++) {
            result[i + 1] = logProof[i];
        }
    }
}
