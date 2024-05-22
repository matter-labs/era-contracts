// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {L2Message, L2Log} from "contracts/common/Messaging.sol";
import "forge-std/Test.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, L1_GAS_PER_PUBDATA_BYTE, L2_TO_L1_LOG_SERIALIZE_SIZE} from "contracts/common/Config.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_BOOTLOADER_ADDRESS} from "contracts/common/L2ContractAddresses.sol";
import {Merkle} from "contracts/state-transition/libraries/Merkle.sol";
import {MurkyBase} from "murky/common/MurkyBase.sol";
import {MerkleTest} from "contracts/dev-contracts/test/MerkleTest.sol";
import {TxStatus} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";
import {Bridgehub} from "contracts/bridgehub/Bridgehub.sol";
import {MailboxFacet} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";

contract MerkleTree is MurkyBase {
    /// The original Merkle tree contains the ascending sort and concat prior to hashing, so we need to override it
    function hashLeafPairs(bytes32 left, bytes32 right) public pure override returns (bytes32 _hash) {
        assembly {
            mstore(0x0, left)
            mstore(0x20, right)
            _hash := keccak256(0x0, 0x40)
        }
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}

contract MailboxL2LogsProve is MailboxTest {
    bytes32[] elements;
    MerkleTest merkle;
    MerkleTree merkleTree;
    bytes data;
    uint256 batchNumber;
    bool isService;
    uint8 shardId;

    function setUp() public virtual {
        prepare();

        data = abi.encodePacked("test data");
        merkleTree = new MerkleTree();
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
        bytes32[] memory proof = new bytes32[](0);

        vm.expectRevert(bytes("xx"));
        mailboxFacet.proveL2MessageInclusion({
            _batchNumber: batchNumber + 1,
            _index: 0,
            _message: message,
            _proof: proof
        });
    }

    function test_success_proveL2MessageInclussion() public {
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
        utilsFacet.util_setl2LogsRootHash(batchNumber, root);

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
        bool ret = mailboxFacet.proveL2MessageInclusion(batchNumber, firstLogIndex, message, firstLogProof);

        // Assert that the proof was successful
        assertEq(ret, true);

        // Prove L2 message inclusion for wrong leaf
        ret = mailboxFacet.proveL2MessageInclusion(batchNumber, secondLogIndex, message, firstLogProof);

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
        utilsFacet.util_setl2LogsRootHash(batchNumber, root);

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
        bool ret = mailboxFacet.proveL2LogInclusion({
            _batchNumber: batchNumber,
            _index: secondLogIndex,
            _proof: secondLogProof,
            _log: log
        });

        // Assert that the proof was successful
        assertEq(ret, true);

        // Prove l2 log inclusion with wrong proof
        ret = mailboxFacet.proveL2LogInclusion({
            _batchNumber: batchNumber,
            _index: firstLogIndex,
            _proof: secondLogProof,
            _log: log
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
        utilsFacet.util_setl2LogsRootHash(batchNumber, root);

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
        vm.expectRevert(bytes("tw"));
        mailboxFacet.proveL2LogInclusion({
            _batchNumber: batchNumber,
            _index: secondLogIndex,
            _proof: secondLogProof,
            _log: log
        });
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
        utilsFacet.util_setl2LogsRootHash(batchNumber, root);

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
        bool ret = mailboxFacet.proveL1ToL2TransactionStatus({
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
}
