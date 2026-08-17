// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MailboxTest} from "./_Mailbox_Shared.t.sol";
import {
    L2CanonicalTransaction,
    L2Log,
    L2Message,
    MessageInclusionProof,
    TxStatus
} from "contracts/common/Messaging.sol";
import "forge-std/Test.sol";
import {L2_TO_L1_LOG_SERIALIZE_SIZE} from "contracts/common/Config.sol";
import {
    L2_BOOTLOADER_ADDRESS,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {HashedLogIsDefault} from "contracts/common/L1ContractErrors.sol";

import {MerkleTest} from "contracts/dev-contracts/test/MerkleTest.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {InvalidSettlementLayerForBatch} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {MigrationInterval} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";

import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {L1MessageRootDev} from "contracts/dev-contracts/L1MessageRootDev.sol";
import {MerkleTreeNoSort} from "test/foundry/l1/unit/concrete/common/libraries/Merkle/MerkleTreeNoSort.sol";
import {MessageHashing, ProofData} from "contracts/common/libraries/MessageHashing.sol";

import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

/// @notice Covers `L1MessageRoot`'s verification of a chain's L2 logs. The chain under proof is the
/// Mailbox test fixture's diamond, because the paths exercised here are the ones that read chain state:
/// the `_noBatchFallback` lookup of `l2LogsRootHash` for pre-v31 batches, and the recursive
/// settlement-layer proof with its migration-interval validation. Leaf hashing itself is covered by
/// `Libraries/Merkle` and `Libraries/MessageHashing`, and the L2 side by `Bridgehub/L2MessageVerification`.
contract MessageRootChainLogProofs is MailboxTest {
    bytes32[] elements;
    MerkleTest merkle;
    MerkleTreeNoSort merkleTree;
    bytes data;
    uint256 batchNumber;
    /// @dev Cached so that proof calls made after `vm.expectRevert` do not issue an extra external call.
    uint256 chainId;
    bool isService;
    uint8 shardId;
    L1MessageRoot messageRoot;

    /// @dev Gateway chain ID used for legacy historical migration intervals.
    uint256 constant LEGACY_GW_CHAIN_ID = 1;

    function setUp() public virtual {
        setupDiamondProxy();

        // MessageRoot rejects batch zero proofs, so keep tests on a non-zero executed batch.
        // Use batch 2 so that we can set migrateToGWBatchNumber=1 (must be >0).
        utilsFacet.util_setTotalBatchesExecuted(2);
        batchNumber = gettersFacet.getTotalBatchesExecuted();
        chainId = gettersFacet.getChainId();

        // Mock getAllZKChainChainIDs to return the test chain so v31 upgrade sets the placeholder
        uint256[] memory chainIds = new uint256[](1);
        chainIds[0] = gettersFacet.getChainId();
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(chainIds)
        );
        vm.mockCall(
            address(bridgehub),
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, gettersFacet.getChainId()),
            abi.encode(block.chainid)
        );

        // Deploy messageRoot as a proxy with v31 upgrade initialization so that
        // v31UpgradeChainBatchNumber is set to the placeholder value, enabling
        // _noBatchFallback to query l2LogsRootHash from the chain directly.
        messageRoot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(
                        new L1MessageRootDev(address(bridgehub), LEGACY_GW_CHAIN_ID, address(realChainAssetHandler))
                    ),
                    address(uint160(1)),
                    abi.encodeCall(L1MessageRootDev.stampV31Placeholders, ())
                )
            )
        );

        vm.mockCall(
            address(bridgehub),
            abi.encodeCall(IBridgehubBase.messageRoot, ()),
            abi.encode(address(messageRoot))
        );
        vm.mockCall(address(bridgehub), abi.encodeCall(IBridgehubBase.assetRouter, ()), abi.encode(address(0)));
        realChainAssetHandler.setAddresses();
        vm.mockCall(
            address(bridgehub),
            abi.encodeCall(IBridgehubBase.getZKChain, (gettersFacet.getChainId())),
            abi.encode(address(mailboxFacet))
        );

        data = abi.encodePacked("test data");
        merkleTree = new MerkleTreeNoSort();
        merkle = new MerkleTest();
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

    function test_FailWhen_batchNumberGreaterThanBatchesExecuted() public {
        L2Message memory message = L2Message({txNumberInBatch: 0, sender: sender, data: data});
        bytes32[] memory proof = _appendProofMetadata(new bytes32[](1));

        // Mailbox delegates verification to MessageRoot.
        // MessageRoot does not revert with BatchNotExecuted on out-of-range batches; it returns false.
        bool result = _proveL2MessageInclusion({
            _batchNumber: batchNumber + 1,
            _index: 0,
            _message: message,
            _proof: proof,
            _expectedError: bytes("")
        });
        assertFalse(result);
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

    /// @dev Sets up a historical migration interval so that `batchNumber` (the main chain's batch)
    ///      falls within the SL range for `_settlementLayerChainId`, making it a valid settlement layer.
    function _setupSettlementForChain(uint256 _settlementLayerChainId) internal {
        // The main chain's batchNumber is 2 (set in setUp).
        // Place the migration boundary at batch 1 so batch 2 is inside the SL interval.
        // Use a large migrateFromGWBatchNumber so all test batches fall within the interval.
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: batchNumber - 1, // batch 1
            migrateFromGWBatchNumber: 1000,
            settlementLayerBatchLowerBound: 0,
            settlementLayerBatchUpperBound: type(uint256).max,
            settlementLayerChainId: _settlementLayerChainId,
            isActive: false
        });
        // setHistoricalMigrationInterval only accepts migration number 0 and the legacy GW chain ID.
        // We use LEGACY_GW_CHAIN_ID as the settlement layer to match this constraint.
        realChainAssetHandler.setHistoricalMigrationInterval(gettersFacet.getChainId(), 0, interval);
    }

    function checkRecursiveLeafProof(
        RecursiveProofInfo memory proofInfo,
        bool shouldSetupValidSL
    ) internal returns (bool) {
        address secondDiamondProxy = deployDiamondProxy();

        UtilsFacet secondUtils = UtilsFacet(secondDiamondProxy);
        IGetters secondGetters = IGetters(secondDiamondProxy);

        secondUtils.util_setTotalBatchesExecuted(1);
        uint256 secondBatchNumber = secondGetters.getTotalBatchesExecuted();

        (bytes32[] memory proof, bytes32 requiredRoot) = _composeRecursiveProof(
            RecursiveProofInfo({
                leaf: proofInfo.leaf,
                logProof: proofInfo.logProof,
                leafProofMask: proofInfo.leafProofMask,
                // We override it since it is only known here
                batchNumber: batchNumber,
                l1Timestamp: 0,
                batchProof: proofInfo.batchProof,
                batchLeafProofMask: proofInfo.batchLeafProofMask,
                // We override it since it is only known here
                settlementLayerBatchNumber: secondBatchNumber,
                settlementLayerBatchRootMask: proofInfo.settlementLayerBatchRootMask,
                settlementLayerChainId: proofInfo.settlementLayerChainId,
                chainIdProof: proofInfo.chainIdProof
            })
        );
        secondUtils.util_setL2LogsRootHash(secondBatchNumber, requiredRoot);
        assertEq(secondGetters.l2LogsRootHash(secondBatchNumber), requiredRoot);

        // Use setHistoricalMigrationInterval on the real ChainAssetHandler to mark
        // the settlement layer as valid (or leave it unset for invalid cases).
        if (shouldSetupValidSL) {
            _setupSettlementForChain(proofInfo.settlementLayerChainId);
        }

        vm.mockCall(
            address(bridgehub),
            abi.encodeCall(IBridgehubBase.getZKChain, (proofInfo.settlementLayerChainId)),
            abi.encode(secondDiamondProxy)
        );
        if (!shouldSetupValidSL) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    InvalidSettlementLayerForBatch.selector,
                    gettersFacet.getChainId(),
                    batchNumber,
                    proofInfo.settlementLayerChainId
                )
            );
        }

        return
            messageRoot.proveL2LeafInclusionShared(
                chainId,
                batchNumber,
                proofInfo.leafProofMask,
                proofInfo.leaf,
                proof
            );
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
                    l1Timestamp: 0,
                    batchProof: bytes32Arr(2, bytes32(uint256(1)), bytes32(uint256(1))),
                    batchLeafProofMask: 1,
                    // We override it since it is only known here
                    settlementLayerBatchNumber: 0,
                    settlementLayerBatchRootMask: 3,
                    settlementLayerChainId: LEGACY_GW_CHAIN_ID,
                    chainIdProof: bytes32Arr(2, bytes32(uint256(1)), bytes32(uint256(0)))
                }),
                true
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
                    l1Timestamp: 0,
                    batchProof: bytes32Arr(0, bytes32(0), bytes32(0)),
                    batchLeafProofMask: 0,
                    // We override it since it is only known here
                    settlementLayerBatchNumber: 0,
                    settlementLayerBatchRootMask: 3,
                    settlementLayerChainId: LEGACY_GW_CHAIN_ID,
                    chainIdProof: bytes32Arr(2, bytes32(uint256(1)), bytes32(uint256(0)))
                }),
                true
            )
        );
    }

    function test_RevertWhen_recursiveProofInvalidSettlementLayer() external {
        RecursiveProofInfo memory proofInfo = RecursiveProofInfo({
            leaf: bytes32(0),
            logProof: bytes32Arr(2, bytes32(0), bytes32(uint256(1))),
            leafProofMask: 2,
            // We override it since it is only known here
            batchNumber: 0,
            l1Timestamp: 0,
            batchProof: bytes32Arr(2, bytes32(uint256(1)), bytes32(uint256(1))),
            batchLeafProofMask: 1,
            // We override it since it is only known here
            settlementLayerBatchNumber: 0,
            settlementLayerBatchRootMask: 3,
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            chainIdProof: bytes32Arr(2, bytes32(uint256(1)), bytes32(uint256(0)))
        });

        // Don't set up a valid settlement layer, so isValidSettlementLayer returns false.
        checkRecursiveLeafProof(proofInfo, false);
    }

    function test_RevertWhen_recursiveProofBatchBeforeMigration() external {
        // Set up a historical migration where the chain migrated at batch 5.
        // Our batchNumber is 1, which is BEFORE the migration.
        // The proof claims the batch is on the GW, but it should be on L1.
        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 5,
            migrateFromGWBatchNumber: 100,
            settlementLayerBatchLowerBound: 0,
            settlementLayerBatchUpperBound: type(uint256).max,
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            isActive: false
        });
        realChainAssetHandler.setHistoricalMigrationInterval(gettersFacet.getChainId(), 0, interval);

        RecursiveProofInfo memory proofInfo = RecursiveProofInfo({
            leaf: bytes32(0),
            logProof: bytes32Arr(2, bytes32(0), bytes32(uint256(1))),
            leafProofMask: 2,
            batchNumber: 0,
            l1Timestamp: 0,
            batchProof: bytes32Arr(2, bytes32(uint256(1)), bytes32(uint256(1))),
            batchLeafProofMask: 1,
            settlementLayerBatchNumber: 0,
            settlementLayerBatchRootMask: 3,
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            chainIdProof: bytes32Arr(2, bytes32(uint256(1)), bytes32(uint256(0)))
        });

        // The proof claims GW as settlement layer, but batchNumber=2 <= migrateToGWBatchNumber=5,
        // so the batch was on L1. This should revert.
        address secondDiamondProxy = deployDiamondProxy();

        UtilsFacet secondUtils = UtilsFacet(secondDiamondProxy);
        IGetters secondGetters = IGetters(secondDiamondProxy);
        secondUtils.util_setTotalBatchesExecuted(1);
        uint256 secondBatchNumber = secondGetters.getTotalBatchesExecuted();

        (bytes32[] memory proof, bytes32 requiredRoot) = _composeRecursiveProof(
            RecursiveProofInfo({
                leaf: proofInfo.leaf,
                logProof: proofInfo.logProof,
                leafProofMask: proofInfo.leafProofMask,
                batchNumber: batchNumber,
                l1Timestamp: 0,
                batchProof: proofInfo.batchProof,
                batchLeafProofMask: proofInfo.batchLeafProofMask,
                settlementLayerBatchNumber: secondBatchNumber,
                settlementLayerBatchRootMask: proofInfo.settlementLayerBatchRootMask,
                settlementLayerChainId: proofInfo.settlementLayerChainId,
                chainIdProof: proofInfo.chainIdProof
            })
        );
        secondUtils.util_setL2LogsRootHash(secondBatchNumber, requiredRoot);

        vm.mockCall(
            address(bridgehub),
            abi.encodeCall(IBridgehubBase.getZKChain, (proofInfo.settlementLayerChainId)),
            abi.encode(secondDiamondProxy)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidSettlementLayerForBatch.selector,
                gettersFacet.getChainId(),
                batchNumber,
                LEGACY_GW_CHAIN_ID
            )
        );
        messageRoot.proveL2LeafInclusionShared(chainId, batchNumber, proofInfo.leafProofMask, proofInfo.leaf, proof);
    }

    function test_RevertWhen_recursiveProofBatchAfterReturnFromSL() external {
        // Chain migrated to GW at batch 1, returned at batch 5.
        // We set batchNumber=10 which is after the return → on L1.
        // The proof claims GW → should revert.
        utilsFacet.util_setTotalBatchesExecuted(10);
        batchNumber = 10;

        MigrationInterval memory interval = MigrationInterval({
            migrateToGWBatchNumber: 1,
            migrateFromGWBatchNumber: 5,
            settlementLayerBatchLowerBound: 0,
            settlementLayerBatchUpperBound: type(uint256).max,
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            isActive: false
        });
        realChainAssetHandler.setHistoricalMigrationInterval(gettersFacet.getChainId(), 0, interval);

        RecursiveProofInfo memory proofInfo = RecursiveProofInfo({
            leaf: bytes32(0),
            logProof: bytes32Arr(2, bytes32(0), bytes32(uint256(1))),
            leafProofMask: 2,
            batchNumber: 0,
            l1Timestamp: 0,
            batchProof: bytes32Arr(2, bytes32(uint256(1)), bytes32(uint256(1))),
            batchLeafProofMask: 1,
            settlementLayerBatchNumber: 0,
            settlementLayerBatchRootMask: 3,
            settlementLayerChainId: LEGACY_GW_CHAIN_ID,
            chainIdProof: bytes32Arr(2, bytes32(uint256(1)), bytes32(uint256(0)))
        });

        // Batch 10 is after return from SL → on L1. Proof claims GW → should revert.
        address secondDiamondProxy = deployDiamondProxy();

        UtilsFacet secondUtils = UtilsFacet(secondDiamondProxy);
        IGetters secondGetters = IGetters(secondDiamondProxy);
        secondUtils.util_setTotalBatchesExecuted(1);
        uint256 secondBatchNumber = secondGetters.getTotalBatchesExecuted();

        (bytes32[] memory proof, bytes32 requiredRoot) = _composeRecursiveProof(
            RecursiveProofInfo({
                leaf: proofInfo.leaf,
                logProof: proofInfo.logProof,
                leafProofMask: proofInfo.leafProofMask,
                batchNumber: batchNumber,
                l1Timestamp: 0,
                batchProof: proofInfo.batchProof,
                batchLeafProofMask: proofInfo.batchLeafProofMask,
                settlementLayerBatchNumber: secondBatchNumber,
                settlementLayerBatchRootMask: proofInfo.settlementLayerBatchRootMask,
                settlementLayerChainId: proofInfo.settlementLayerChainId,
                chainIdProof: proofInfo.chainIdProof
            })
        );
        secondUtils.util_setL2LogsRootHash(secondBatchNumber, requiredRoot);

        vm.mockCall(
            address(bridgehub),
            abi.encodeCall(IBridgehubBase.getZKChain, (proofInfo.settlementLayerChainId)),
            abi.encode(secondDiamondProxy)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidSettlementLayerForBatch.selector,
                gettersFacet.getChainId(),
                batchNumber,
                LEGACY_GW_CHAIN_ID
            )
        );
        messageRoot.proveL2LeafInclusionShared(chainId, batchNumber, proofInfo.leafProofMask, proofInfo.leaf, proof);
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
        bool retOldEncoding = messageRoot.proveL1ToL2TransactionStatusShared({
            _chainId: chainId,
            _l2TxHash: _l2TxHash,
            _l2BatchNumber: _l2BatchNumber,
            _l2MessageIndex: _l2MessageIndex,
            _l2TxNumberInBatch: _l2TxNumberInBatch,
            _merkleProof: _merkleProof,
            _status: _status
        });
        bool retNewEncoding = messageRoot.proveL1ToL2TransactionStatusShared({
            _chainId: chainId,
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
        bool retOldEncoding = messageRoot.proveL2LogInclusionShared({
            _chainId: chainId,
            _blockOrBatchNumber: _batchNumber,
            _index: _index,
            _proof: _proof,
            _log: _log
        });

        if (_expectedError.length > 0) {
            vm.expectRevert(_expectedError);
        }
        bool retNewEncoding = messageRoot.proveL2LogInclusionShared({
            _chainId: chainId,
            _blockOrBatchNumber: _batchNumber,
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
        bool retOldEncoding = messageRoot.proveL2MessageInclusionShared({
            _chainId: chainId,
            _blockOrBatchNumber: _batchNumber,
            _index: _index,
            _message: _message,
            _proof: _proof
        });

        if (_expectedError.length > 0) {
            vm.expectRevert(_expectedError);
        }
        bool retNewEncoding = messageRoot.proveL2MessageInclusionShared({
            _chainId: chainId,
            _blockOrBatchNumber: _batchNumber,
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
        uint256 l1Timestamp;
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
        proof = new bytes32[](
            1 + info.logProof.length + 1 + 1 + info.batchProof.length + 2 + 1 + info.chainIdProof.length
        );
        proof[ptr++] = _composeMetadata(info.logProof.length, info.batchProof.length, false);
        copyBytes32(proof, info.logProof, ptr);
        ptr += info.logProof.length;

        bytes32 batchSettlementRoot = Merkle.calculateRootMemory(info.logProof, info.leafProofMask, info.leaf);

        // The l1 timestamp word is read right after the log-leaf proof and bound into the batch leaf.
        proof[ptr++] = bytes32(info.l1Timestamp);

        bytes32 batchLeafHash = MessageHashing.batchLeafHash(batchSettlementRoot, info.batchNumber, info.l1Timestamp);

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
