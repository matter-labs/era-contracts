// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {L2CanonicalTransaction, L2Log, L2Message, MessageInclusionProof} from "contracts/common/Messaging.sol";
import "forge-std/Test.sol";
import {L2_TO_L1_LOG_SERIALIZE_SIZE} from "contracts/common/Config.sol";
import {L2_BOOTLOADER_ADDRESS, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {BatchNotExecuted, HashedLogIsDefault} from "contracts/common/L1ContractErrors.sol";

import {MerkleTest} from "contracts/dev-contracts/test/MerkleTest.sol";
import {TxStatus} from "contracts/state-transition/chain-deps/facets/Mailbox.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {MerkleTreeNoSort} from "test/foundry/l1/unit/concrete/common/libraries/Merkle/MerkleTreeNoSort.sol";
import {MessageHashing, ProofData} from "contracts/common/libraries/MessageHashing.sol";
import {IMailbox} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

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
            _sender: address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
            _key: bytes32(uint256(uint160(sender))),
            _value: keccak256(data)
        });

        uint256 secondLogIndex = _addHashedLogToMerkleTree({
            _shardId: 0,
            _isService: true,
            _txNumberInBatch: 1,
            _sender: address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
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
            _sender: address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
            _key: bytes32(uint256(uint160(sender))),
            _value: keccak256(data)
        });

        uint256 secondLogIndex = _addHashedLogToMerkleTree({
            _shardId: shardId,
            _isService: isService,
            _txNumberInBatch: 1,
            _sender: address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
            _key: bytes32(uint256(uint160(sender))),
            _value: keccak256(data)
        });

        L2Log memory log = L2Log({
            l2ShardId: shardId,
            isService: isService,
            txNumberInBatch: 1,
            sender: address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
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
            _sender: address(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR),
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

    function checkRecursiveLeafProof(RecursiveProofInfo memory proofInfo) internal returns (bool) {
        address secondDiamondProxy = deployDiamondProxy();

        IMailbox secondMailbox = IMailbox(secondDiamondProxy);
        UtilsFacet secondUtils = UtilsFacet(secondDiamondProxy);
        IGetters secondGetters = IGetters(secondDiamondProxy);

        uint256 secondBatchNumber = secondGetters.getTotalBatchesExecuted();

        (bytes32[] memory proof, bytes32 requiredRoot) = _composeRecursiveProof(
            RecursiveProofInfo({
                leaf: proofInfo.leaf,
                logProof: proofInfo.logProof,
                leafProofMask: proofInfo.leafProofMask,
                // We override it since it is only known here
                batchNumber: batchNumber,
                batchProof: proofInfo.batchProof,
                batchLeafProofMask: proofInfo.batchLeafProofMask,
                // We override it since it is only known here
                settlementLayerBatchNumber: secondBatchNumber,
                settlementLayerBatchRootMask: proofInfo.settlementLayerBatchRootMask,
                settlementLayerChainId: proofInfo.settlementLayerChainId,
                chainIdProof: proofInfo.chainIdProof
            })
        );
        utilsFacet.util_setL2LogsRootHash(secondBatchNumber, requiredRoot);

        vm.mockCall(
            address(bridgehub),
            abi.encodeCall(IBridgehubBase.whitelistedSettlementLayers, (proofInfo.settlementLayerChainId)),
            abi.encode(true)
        );
        vm.mockCall(
            address(bridgehub),
            abi.encodeCall(IBridgehubBase.getZKChain, (proofInfo.settlementLayerChainId)),
            abi.encode(secondDiamondProxy)
        );

        return mailboxFacet.proveL2LeafInclusion(batchNumber, proofInfo.leafProofMask, proofInfo.leaf, proof);
    }

    function test_successRecursiveProof() external {
        assertTrue(
            checkRecursiveLeafProof(
                RecursiveProofInfo({
                    leaf: bytes32(0),
                    logProof: bytes32Arr(2, bytes32(0), bytes32(uint256(1))),
                    leafProofMask: 2,
                    // We override it since it is only known here
                    batchNumber: 0,
                    batchProof: bytes32Arr(2, bytes32(uint256(1)), bytes32(uint256(1))),
                    batchLeafProofMask: 1,
                    // We override it since it is only known here
                    settlementLayerBatchNumber: 0,
                    settlementLayerBatchRootMask: 3,
                    settlementLayerChainId: 255,
                    chainIdProof: bytes32Arr(2, bytes32(uint256(1)), bytes32(uint256(0)))
                })
            )
        );
    }

    function test_successRecursiveProofZeroLength() external {
        assertTrue(
            checkRecursiveLeafProof(
                RecursiveProofInfo({
                    leaf: bytes32(0),
                    logProof: bytes32Arr(2, bytes32(0), bytes32(uint256(1))),
                    leafProofMask: 2,
                    // We override it since it is only known here
                    batchNumber: 0,
                    batchProof: bytes32Arr(0, bytes32(0), bytes32(0)),
                    batchLeafProofMask: 0,
                    // We override it since it is only known here
                    settlementLayerBatchNumber: 0,
                    settlementLayerBatchRootMask: 3,
                    settlementLayerChainId: 255,
                    chainIdProof: bytes32Arr(2, bytes32(uint256(1)), bytes32(uint256(0)))
                })
            )
        );
    }

    function test_calculateRoot() public {
        // these txs can be printed out in the server.
        bytes
            memory txData = hex"00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000071000000000000000000000000c9c7594f8f60b77dbdacdc374c5ef822d5733fa700000000000000000000000000000000000000000000000000000000000100090000000000000000000000000000000000000000000000000000000001c9c380000000000000000000000000000000000000000000000000000000000000c350000000000000000000000000000000000000000000000000000000000bebc200000000000000000000000000000000000000000000000000000000000bebc200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000050000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002600000000000000000000000000000000000000000000000000000000000000b4000000000000000000000000000000000000000000000000000000000000017e00000000000000000000000000000000000000000000000000000000000001800000000000000000000000000000000000000000000000000000000000000182000000000000000000000000000000000000000000000000000000000000008c0000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000002e00000000000000000000000000000000000000000000000000000000000000280000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000001f90000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000800a000000000000000000000000000000000000000000000000000000000000800100000000000000000000000000000000000000000000000002c68af0bb14000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d59d06315439cbf54db8ae7ae50ca8f0f5c29738000000000000000000000000c9c7594f8f60b77dbdacdc374c5ef822d5733fa700000000000000000000000000000000000000000000000002c68af0bb140000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000c9c7594f8f60b77dbdacdc374c5ef822d5733fa700000000000000000000000000000000000000000000000000000000000005c0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000001f90000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000056000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000800a0000000000000000000000000000000000000000000000000000000000008001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000300000000000000000000000000000000000000000000000000000000000100030000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000003249c884fd1000000000000000000000000000000000000000000000000000000000000010f0338e2cc82046e415792e108c850888b4b26d398bc99dc31b4c3df8f45f16728000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000002a0000000000000000000000000c9c7594f8f60b77dbdacdc374c5ef822d5733fa7000000000000000000000000d59d06315439cbf54db8ae7ae50ca8f0f5c297380000000000000000000000003d95b0fb27c1de0018d61d1a858c2fd21a72d13b000000000000000000000000000000000000000000000000016345785d8a000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001c101000000000000000000000000000000000000000000000000000000000000010f000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000180000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000007546f6b656e2041000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000024141000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000000120000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c80000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000004c000000000000000000000000000000000000000000000000000000000000004600000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000010f0000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000003a00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000800000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000280000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000001f90000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000022000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000800a000000000000000000000000000000000000000000000000000000000000800100000000000000000000000000000000000000000000000002c68af0bb14000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d59d06315439cbf54db8ae7ae50ca8f0f5c29738000000000000000000000000c9c7594f8f60b77dbdacdc374c5ef822d5733fa700000000000000000000000000000000000000000000000002c68af0bb140000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000c9c7594f8f60b77dbdacdc374c5ef822d5733fa700000000000000000000000000000000000000000000000000000000000000040103000100000000000000000000000000000000000000000000000000000000c71ea440e57fddd8a73a031a4fbc206c65dd4d1c6e55c9e43a52732a67f39b7c24281d22a628042d2746797ee386a7e70d6bdb3355198978c22cf4aa6326fb56e4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf7594400000000000000000000000000000000000000000000000000000000000007a00000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000010f0000000000000000000000000000000000000000000000000000000000000009000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000006e000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010008000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000005c0000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000001f90000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000056000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000e0000000000000000000000000000000000000000000000000000000000000800a0000000000000000000000000000000000000000000000000000000000008001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000300000000000000000000000000000000000000000000000000000000000100030000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000003249c884fd1000000000000000000000000000000000000000000000000000000000000010f0338e2cc82046e415792e108c850888b4b26d398bc99dc31b4c3df8f45f16728000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000002a0000000000000000000000000c9c7594f8f60b77dbdacdc374c5ef822d5733fa7000000000000000000000000d59d06315439cbf54db8ae7ae50ca8f0f5c297380000000000000000000000003d95b0fb27c1de0018d61d1a858c2fd21a72d13b000000000000000000000000000000000000000000000000016345785d8a000000000000000000000000000000000000000000000000000000000000000000a000000000000000000000000000000000000000000000000000000000000001c101000000000000000000000000000000000000000000000000000000000000010f000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000180000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000007546f6b656e20410000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000000241410000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000040103000100000000000000000000000000000000000000000000000000000000579f6c638b50723ea754b2b6046d5f0efb55d8344d0c4e9f602ad137411d909a24281d22a628042d2746797ee386a7e70d6bdb3355198978c22cf4aa6326fb56e4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf75944000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000";
        L2CanonicalTransaction memory trx = abi.decode(txData, (L2CanonicalTransaction));
        (bytes memory paymasterBundle, ) = abi.decode(trx.data, (bytes, bytes));
        (bytes memory paymasterProof, ) = abi.decode(trx.signature, (bytes, bytes));
        MessageInclusionProof memory paymasterInclusionProof = abi.decode(paymasterProof, (MessageInclusionProof));
        paymasterInclusionProof.message.data = paymasterBundle;
        // console.log("chainId", paymasterInclusionProof.chainId);
        // console.log("l1BatchNumber", paymasterInclusionProof.l1BatchNumber);
        // console.log("l2MessageIndex", paymasterInclusionProof.l2MessageIndex);
        // // console.logBytes(trx.data);
        // console.log(trx.to);
        // console.log("l2TxNumberInBlock", paymasterInclusionProof.message[0]);
        // console.log("l2Sender", paymasterInclusionProof.message[1]);
        // console.log("l2Data", paymasterInclusionProof.message[2]);
        // for (uint256 i = 0; i < paymasterInclusionProof.proof.length; i++) {
        //     console.logBytes32(paymasterInclusionProof.proof[i]);
        // }
        ProofData memory result = this.getMessageHash(
            paymasterInclusionProof.chainId,
            paymasterInclusionProof.l1BatchNumber,
            paymasterInclusionProof.l2MessageIndex,
            paymasterInclusionProof.message,
            paymasterInclusionProof.proof
        );
        // console.logBytes32(result.batchSettlementRoot);
        // // assertEq(proofHash, hashedLog);
    }

    function getMessageHash(
        uint256 _chainId,
        uint256 _l1BatchNumber,
        uint256 _l2MessageIndex,
        L2Message calldata _message,
        bytes32[] calldata _proof
    ) public returns (ProofData memory) {
        L2Log memory _log = _L2MessageToLog(_message);
        // console.log("Log l2");
        // console.log(_log.sender);
        // console.log(_log.txNumberInBatch);
        // console.logBytes32(_log.key);
        // console.logBytes32(_log.value);
        bytes32 hashedLog = keccak256(
            // solhint-disable-next-line func-named-parameters
            abi.encodePacked(_log.l2ShardId, _log.isService, _log.txNumberInBatch, _log.sender, _log.key, _log.value)
        );
        return MessageHashing._getProofData(_chainId, _l1BatchNumber, _l2MessageIndex, hashedLog, _proof);
    }

    /// @dev Convert arbitrary-length message to the raw l2 log
    function _L2MessageToLog(L2Message calldata _message) internal pure returns (L2Log memory) {
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

    function _composeMetadata(uint256 proofLen, uint256 batchProofLen, bool finalNode) internal pure returns (bytes32) {
        return
            bytes32(
                bytes.concat(
                    bytes1(0x01),
                    bytes1(uint8(proofLen)),
                    bytes1(uint8(batchProofLen)),
                    bytes1(uint8(finalNode ? 1 : 0)),
                    bytes28(0)
                )
            );
    }

    /// @notice Appends the proof metadata to the log proof as if the proof is for a batch that settled on L1.
    function _appendProofMetadata(bytes32[] memory logProof) internal returns (bytes32[] memory result) {
        result = new bytes32[](logProof.length + 1);

        result[0] = _composeMetadata(logProof.length, 0, true);
        for (uint256 i = 0; i < logProof.length; i++) {
            result[i + 1] = logProof[i];
        }
    }

    // Just quicker to type than creating new bytes32[] each time,
    function bytes32Arr(uint256 length, bytes32 elem1, bytes32 elem2) internal pure returns (bytes32[] memory result) {
        result = new bytes32[](length);
        if (length > 0) {
            result[0] = elem1;
        }
        if (length > 1) {
            result[1] = elem2;
        }
    }

    struct RecursiveProofInfo {
        bytes32 leaf;
        bytes32[] logProof;
        uint256 leafProofMask;
        uint256 batchNumber;
        bytes32[] batchProof;
        uint256 batchLeafProofMask;
        uint256 settlementLayerBatchNumber;
        uint256 settlementLayerBatchRootMask;
        uint256 settlementLayerChainId;
        bytes32[] chainIdProof;
    }

    function _composeRecursiveProof(
        RecursiveProofInfo memory info
    ) internal returns (bytes32[] memory proof, bytes32 chainBRoot) {
        uint256 ptr;
        proof = new bytes32[](1 + info.logProof.length + 1 + info.batchProof.length + 2 + 1 + info.chainIdProof.length);
        proof[ptr++] = _composeMetadata(info.logProof.length, info.batchProof.length, false);
        copyBytes32(proof, info.logProof, ptr);
        ptr += info.logProof.length;

        bytes32 batchSettlementRoot = Merkle.calculateRootMemory(info.logProof, info.leafProofMask, info.leaf);

        bytes32 batchLeafHash = MessageHashing.batchLeafHash(batchSettlementRoot, info.batchNumber);

        proof[ptr++] = bytes32(uint256(info.batchLeafProofMask));
        copyBytes32(proof, info.batchProof, ptr);
        ptr += info.batchProof.length;

        bytes32 chainIdRoot = Merkle.calculateRootMemory(info.batchProof, info.batchLeafProofMask, batchLeafHash);

        bytes32 chainIdLeaf = MessageHashing.chainIdLeafHash(chainIdRoot, gettersFacet.getChainId());

        uint256 settlementLayerPackedBatchInfo = (info.settlementLayerBatchNumber << 128) +
            (info.settlementLayerBatchRootMask);
        proof[ptr++] = bytes32(settlementLayerPackedBatchInfo);
        proof[ptr++] = bytes32(info.settlementLayerChainId);

        proof[ptr++] = _composeMetadata(info.chainIdProof.length, 0, true);
        copyBytes32(proof, info.chainIdProof, ptr);
        ptr += info.chainIdProof.length;

        // Just in case
        require(proof.length == ptr, "Incorrect ptr");

        chainBRoot = Merkle.calculateRootMemory(info.chainIdProof, info.settlementLayerBatchRootMask, chainIdLeaf);
    }

    function copyBytes32(bytes32[] memory to, bytes32[] memory from, uint256 pos) internal pure {
        for (uint256 i = 0; i < from.length; i++) {
            to[pos + i] = from[i];
        }
    }
}
