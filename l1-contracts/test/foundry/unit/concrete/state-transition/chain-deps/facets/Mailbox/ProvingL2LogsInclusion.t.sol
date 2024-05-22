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

contract MaibloxL2LogsProve is MailboxTest {
    bytes32[] elements;
    MerkleTest merkle;
    MerkleTree merkleTree;

    function test_RevertWhen_batchNumberGreaterThanBatchesExecuted() public {
        uint256 totalBatchesExecuted = gettersFacet.getTotalBatchesExecuted();
        address sender = makeAddr("l2sender");
        uint256 batchNumber = totalBatchesExecuted + 1;
        uint256 index = 0;
        L2Message memory message = L2Message({txNumberInBatch: 0, sender: sender, data: abi.encodePacked("test")});
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(bytes("xx"));
        mailboxFacet.proveL2MessageInclusion(batchNumber, index, message, proof);
    }

    //  require(hashedLog != L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, "tw");
    // this is not possible in case of message, because some default values
    // are set during translation from message to log
    function test_successful_proveL2MessageInclussion() public {
        merkleTree = new MerkleTree();
        merkle = new MerkleTest();
        address sender = makeAddr("sender");
        bytes memory data = abi.encodePacked("123");
        uint256 index = 0;

        // Add first element to the Merkle tree
        elements.push(
            keccak256(
                abi.encodePacked(
                    uint8(0),
                    true,
                    uint16(0),
                    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
                    bytes32(uint256(uint160(sender))),
                    keccak256(data)
                )
            )
        );
        index += 1;

        // Add second element to the Merkle tree
        elements.push(
            keccak256(
                abi.encodePacked(
                    uint8(0),
                    true,
                    uint16(1),
                    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
                    bytes32(uint256(uint160(sender))),
                    keccak256(data)
                )
            )
        );

        // Calculate the Merkle root
        bytes32 root = merkleTree.getRoot(elements);
        utilsFacet.util_setl2LogsRootHash(0, root);

        // Create L2 message
        L2Message memory message = L2Message({txNumberInBatch: 0, sender: sender, data: data});

        // Get Merkle proof for the first element
        bytes32[] memory proof = merkleTree.getProof(elements, 0);

        // Calculate the root using the Merkle proof
        bytes32 leaf = elements[0];
        uint256 leafIndex = 0;
        bytes32 calculatedRoot = merkle.calculateRoot(proof, leafIndex, leaf);

        // Assert that the calculated root matches the expected root
        assertEq(calculatedRoot, root);

        // Prove L2 message inclusion
        bool ret = mailboxFacet.proveL2MessageInclusion(0, leafIndex, message, proof);

        // Assert that the proof was successful
        assertEq(ret, true);
    }

    function test_successful_proveL2LogInclusion() public {
        merkleTree = new MerkleTree();
        merkle = new MerkleTest();

        bytes32 secondL2TxHash = keccak256("SecondL2Transaction");
        TxStatus txStatus = TxStatus.Success;
        address sender = L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR;
        address messageSender = makeAddr("sender");
        bytes memory data = abi.encodePacked("123");

        uint8 l2ShardId = 0;
        bool isService = true;
        uint256 indexInTree = 0;
        uint16 txNumberInBatch = 0;

        L2Log memory log = L2Log({
            l2ShardId: l2ShardId,
            isService: isService,
            txNumberInBatch: txNumberInBatch,
            sender: sender,
            key: bytes32(uint256(uint160(messageSender))),
            value: keccak256(data)
        });

        // Add first element to the Merkle tree
        elements.push(
            keccak256(
                abi.encodePacked(
                    l2ShardId,
                    isService,
                    txNumberInBatch,
                    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
                    bytes32(uint256(uint160(messageSender))),
                    keccak256(data)
                )
            )
        );

        // update changing values
        indexInTree += 1;
        txNumberInBatch += 1;

        // Add second element to the Merkle tree
        elements.push(
            keccak256(
                abi.encodePacked(
                    l2ShardId,
                    isService,
                    txNumberInBatch,
                    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
                    bytes32(uint256(uint160(messageSender))),
                    keccak256(data)
                )
            )
        );

        // Calculate the Merkle root
        bytes32 root = merkleTree.getRoot(elements);
        // Set root hash for current batch
        utilsFacet.util_setl2LogsRootHash(0, root);

        // Get Merkle proof for the first element
        bytes32[] memory proof = merkleTree.getProof(elements, 0);

        {
            // Calculate the root using the Merkle proof
            bytes32 leaf = elements[0];
            uint256 leafIndex = 0;
            bytes32 calculatedRoot = merkle.calculateRoot(proof, leafIndex, leaf);
            // Assert that the calculated root matches the expected root
            assertEq(calculatedRoot, root);
        }

        // Prove L1 to L2 transaction status
        bool ret = mailboxFacet.proveL2LogInclusion({_batchNumber: 0, _index: 0, _proof: proof, _log: log});

        // Assert that the proof was successful
        assertEq(ret, true);
    }

    function test_RevertWhen_proveL2LogInclusionDefaultLog() public {
        merkleTree = new MerkleTree();
        merkle = new MerkleTest();

        bytes32 secondL2TxHash = keccak256("SecondL2Transaction");
        TxStatus txStatus = TxStatus.Success;
        address sender = L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR;
        address messageSender = makeAddr("sender");

        uint8 l2ShardId = 0;
        bool isService = false;
        uint256 indexInTree = 0;
        uint16 txNumberInBatch = 0;

        L2Log memory log = L2Log({
            l2ShardId: l2ShardId,
            isService: isService,
            txNumberInBatch: txNumberInBatch,
            sender: address(0),
            key: bytes32(0),
            value: bytes32(0)
        });

        // Add first element to the Merkle tree
        elements.push(keccak256(new bytes(L2_TO_L1_LOG_SERIALIZE_SIZE)));

        txNumberInBatch += 1;
        indexInTree += 1;

        elements.push(
            keccak256(abi.encodePacked(l2ShardId, isService, txNumberInBatch, address(0), bytes32(0), bytes32(0)))
        );

        // Calculate the Merkle root
        bytes32 root = merkleTree.getRoot(elements);
        // Set root hash for current batch
        utilsFacet.util_setl2LogsRootHash(0, root);

        // Get Merkle proof for the first element
        bytes32[] memory proof = merkleTree.getProof(elements, 0);

        {
            // Calculate the root using the Merkle proof
            bytes32 leaf = elements[0];
            uint256 leafIndex = 0;
            bytes32 calculatedRoot = merkle.calculateRoot(proof, leafIndex, leaf);
            // Assert that the calculated root matches the expected root
            assertEq(calculatedRoot, root);
        }

        // Prove L1 to L2 transaction status
        vm.expectRevert(bytes("tw"));
        mailboxFacet.proveL2LogInclusion({_batchNumber: 0, _index: 0, _proof: proof, _log: log});
    }

    function test_successful_proveL1ToL2TransactionStatus() public {
        merkleTree = new MerkleTree();
        merkle = new MerkleTest();

        bytes32 firstL2TxHash = keccak256("firstL2Transaction");
        bytes32 secondL2TxHash = keccak256("SecondL2Transaction");

        TxStatus txStatus = TxStatus.Success;
        address sender = L2_BOOTLOADER_ADDRESS;
        uint8 l2ShardId = 0;
        bool isService = true;

        uint256 indexInTree = 0;
        uint16 txNumberInBatch = 0;

        // Add first element to the Merkle tree
        elements.push(
            keccak256(
                abi.encodePacked(
                    l2ShardId,
                    isService,
                    txNumberInBatch,
                    L2_BOOTLOADER_ADDRESS,
                    firstL2TxHash,
                    bytes32(uint256(txStatus))
                )
            )
        );

        // update changing values
        indexInTree += 1;
        txNumberInBatch += 1;

        // Add second element to the Merkle tree
        elements.push(
            keccak256(
                abi.encodePacked(
                    l2ShardId,
                    isService,
                    txNumberInBatch,
                    L2_BOOTLOADER_ADDRESS,
                    secondL2TxHash,
                    bytes32(uint256(txStatus))
                )
            )
        );

        // Calculate the Merkle root
        bytes32 root = merkleTree.getRoot(elements);
        // Set root hash for current batch
        utilsFacet.util_setl2LogsRootHash(0, root);

        // Get Merkle proof for the first element
        bytes32[] memory proof = merkleTree.getProof(elements, 0);

        {
            // Calculate the root using the Merkle proof
            bytes32 leaf = elements[0];
            uint256 leafIndex = 0;
            bytes32 calculatedRoot = merkle.calculateRoot(proof, leafIndex, leaf);
            // Assert that the calculated root matches the expected root
            assertEq(calculatedRoot, root);
        }

        // Prove L1 to L2 transaction status
        bool ret = mailboxFacet.proveL1ToL2TransactionStatus({
            _l2TxHash: firstL2TxHash,
            _l2BatchNumber: 0,
            _l2MessageIndex: 0,
            _l2TxNumberInBatch: 0,
            _merkleProof: proof,
            _status: txStatus
        });

        // Assert that the proof was successful
        assertEq(ret, true);
    }

}
