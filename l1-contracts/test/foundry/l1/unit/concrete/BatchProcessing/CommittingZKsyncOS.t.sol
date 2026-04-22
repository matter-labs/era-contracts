// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/console.sol";

import {Utils} from "../Utils/Utils.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";

import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {MismatchL2DACommitmentScheme} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {
    InvalidPubdataHash,
    InvalidBlobsPublished,
    BlobNotPublished
} from "../../../da-contracts-imports/DAContractsErrors.sol";
import {BlobsL1DAValidatorZKsyncOS} from "../../../da-contracts-imports/BlobsL1DAValidatorZKsyncOS.sol";

contract CommittingTest is ExecutorTest {
    function isZKsyncOS() internal pure override returns (bool) {
        return true;
    }

    function setUp() public {}

    function test_SuccessfullyCommitBatchWithCalldata() public {
        // Calldata DA
        // With calldata zksync os always produces 1 blob with linear hash equals to zero
        // Generating similar values here
        bytes1 source = bytes1(0);
        bytes32 blobCommitment = bytes32(0);
        bytes32 uncompressedStateDiffHash = bytes32(0);
        bytes memory pubdata = abi.encodePacked((Utils.randomBytes32("pubdata")));
        bytes32 totalL2PubdataHash = keccak256(pubdata);
        uint8 numberOfBlobs = 1;
        bytes32[] memory blobsLinearHashes = new bytes32[](1);

        bytes memory operatorDAInput = abi.encodePacked(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            numberOfBlobs,
            blobsLinearHashes,
            source,
            pubdata,
            blobCommitment
        );

        bytes32 daCommitment = Utils.constructRollupL2DAValidatorOutputHash(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            uint8(numberOfBlobs),
            blobsLinearHashes
        );

        CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;

        CommitBatchInfoZKsyncOS[] memory correctCommitBatchInfoArray = new CommitBatchInfoZKsyncOS[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, correctCommitBatchInfoArray);
        vm.prank(validator);
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_SuccessfullyCommitBatchWithBlobs() public {
        bytes32[] memory blobVersionedHashes = new bytes32[](2);
        blobVersionedHashes[0] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;
        blobVersionedHashes[1] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d6;

        // 2 blobs, which we didn't prepublish
        bytes memory operatorDAInput = abi.encodePacked(bytes32(0), bytes32(0));

        bytes32 daCommitment = keccak256(
            abi.encodePacked(
                bytes32(0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5),
                bytes32(0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d6)
            )
        );

        CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;
        correctNewCommitBatchInfo.daCommitmentScheme = L2DACommitmentScheme.BLOBS_ZKSYNC_OS;

        CommitBatchInfoZKsyncOS[] memory correctCommitBatchInfoArray = new CommitBatchInfoZKsyncOS[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, correctCommitBatchInfoArray);

        // with ZKsync OS we have separate pair for blobs
        address blobsl1DaValidatorZKsyncOS = Utils.deployBlobsL1DAValidatorZKsyncOSBytecode();
        vm.prank(address(owner));
        admin.setDAValidatorPair(blobsl1DaValidatorZKsyncOS, L2DACommitmentScheme.BLOBS_ZKSYNC_OS);

        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_SuccessfullyCommitBatchWithBlobsPrepublished() public {
        bytes32[] memory blobVersionedHashes = new bytes32[](2);
        blobVersionedHashes[0] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;
        blobVersionedHashes[1] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d6;

        // 2 prepublished blobs
        bytes memory operatorDAInput = abi.encodePacked(blobVersionedHashes[0], blobVersionedHashes[1]);

        bytes32 daCommitment = keccak256(
            abi.encodePacked(
                bytes32(0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5),
                bytes32(0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d6)
            )
        );

        CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;
        correctNewCommitBatchInfo.daCommitmentScheme = L2DACommitmentScheme.BLOBS_ZKSYNC_OS;

        CommitBatchInfoZKsyncOS[] memory correctCommitBatchInfoArray = new CommitBatchInfoZKsyncOS[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, correctCommitBatchInfoArray);

        // with ZKsync OS we have separate pair for blobs
        address blobsl1DaValidatorZKsyncOS = Utils.deployBlobsL1DAValidatorZKsyncOSBytecode();
        vm.prank(address(owner));
        admin.setDAValidatorPair(blobsl1DaValidatorZKsyncOS, L2DACommitmentScheme.BLOBS_ZKSYNC_OS);

        vm.blobhashes(blobVersionedHashes);
        BlobsL1DAValidatorZKsyncOS(blobsl1DaValidatorZKsyncOS).publishBlobs();

        vm.prank(validator);
        vm.blobhashes(new bytes32[](0));
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_SuccessfullyCommitBatchValidium() public {
        bytes memory operatorDAInput = abi.encodePacked(
            bytes32(0) // just put zero with zksync os, no need to verify it
        );

        bytes32 daCommitment = bytes32(0); // empty

        CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;
        correctNewCommitBatchInfo.daCommitmentScheme = L2DACommitmentScheme.EMPTY_NO_DA;

        CommitBatchInfoZKsyncOS[] memory correctCommitBatchInfoArray = new CommitBatchInfoZKsyncOS[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, correctCommitBatchInfoArray);

        // with ZKsync OS we have separate pair for blobs
        address validiumL1DAValidator = address(new ValidiumL1DAValidator());
        vm.prank(address(owner));
        admin.setDAValidatorPair(validiumL1DAValidator, L2DACommitmentScheme.EMPTY_NO_DA);

        vm.prank(validator);
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_CommittingWithWrongL2DACommitmentScheme() public {
        bytes32[] memory blobVersionedHashes = new bytes32[](2);
        blobVersionedHashes[0] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;
        blobVersionedHashes[1] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d6;

        // 2 blobs, which we didn't prepublish
        bytes memory operatorDAInput = abi.encodePacked(bytes32(0), bytes32(0));

        bytes32 daCommitment = keccak256(
            abi.encodePacked(
                bytes32(0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5),
                bytes32(0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d6)
            )
        );

        CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;
        correctNewCommitBatchInfo.daCommitmentScheme = L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256;

        CommitBatchInfoZKsyncOS[] memory correctCommitBatchInfoArray = new CommitBatchInfoZKsyncOS[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, correctCommitBatchInfoArray);

        // with ZKsync OS we have separate pair for blobs
        address blobsl1DaValidatorZKsyncOS = Utils.deployBlobsL1DAValidatorZKsyncOSBytecode();
        vm.prank(address(owner));
        admin.setDAValidatorPair(blobsl1DaValidatorZKsyncOS, L2DACommitmentScheme.BLOBS_ZKSYNC_OS);

        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);
        vm.expectRevert(abi.encodeWithSelector(MismatchL2DACommitmentScheme.selector, 3, 4));
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_CommittingWithWrongCalldata() public {
        // Calldata DA
        // With calldata zksync os always produces 1 blob with linear hash equals to zero
        // Generating similar values here
        bytes1 source = bytes1(0);
        bytes32 blobCommitment = bytes32(0);
        bytes32 uncompressedStateDiffHash = bytes32(0);
        bytes memory pubdata = abi.encodePacked((Utils.randomBytes32("pubdata")));
        bytes32 totalL2PubdataHash = bytes32(hex"0123456789012345678901234567890123456789012345678901234567890123"); // hash doesn't correspond to pubdata
        uint8 numberOfBlobs = 1;
        bytes32[] memory blobsLinearHashes = new bytes32[](1);

        bytes memory operatorDAInput = abi.encodePacked(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            numberOfBlobs,
            blobsLinearHashes,
            source,
            pubdata,
            blobCommitment
        );

        bytes32 daCommitment = Utils.constructRollupL2DAValidatorOutputHash(
            uncompressedStateDiffHash,
            totalL2PubdataHash,
            uint8(numberOfBlobs),
            blobsLinearHashes
        );

        CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;

        CommitBatchInfoZKsyncOS[] memory correctCommitBatchInfoArray = new CommitBatchInfoZKsyncOS[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, correctCommitBatchInfoArray);
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(InvalidPubdataHash.selector, totalL2PubdataHash, keccak256(pubdata)));
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_CommittingWithWrongBlobs() public {
        bytes32[] memory blobVersionedHashes = new bytes32[](2);
        blobVersionedHashes[0] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;
        blobVersionedHashes[1] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d7;

        // 2 blobs, which we didn't prepublish
        bytes memory operatorDAInput = abi.encodePacked(bytes32(0), bytes32(0));

        bytes32 daCommitment = keccak256(
            abi.encodePacked(
                bytes32(0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5),
                bytes32(0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d6)
            )
        );

        CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;
        correctNewCommitBatchInfo.daCommitmentScheme = L2DACommitmentScheme.BLOBS_ZKSYNC_OS;

        CommitBatchInfoZKsyncOS[] memory correctCommitBatchInfoArray = new CommitBatchInfoZKsyncOS[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, correctCommitBatchInfoArray);

        // with ZKsync OS we have separate pair for blobs
        address blobsl1DaValidatorZKsyncOS = Utils.deployBlobsL1DAValidatorZKsyncOSBytecode();
        vm.prank(address(owner));
        admin.setDAValidatorPair(blobsl1DaValidatorZKsyncOS, L2DACommitmentScheme.BLOBS_ZKSYNC_OS);

        vm.prank(validator);
        vm.blobhashes(blobVersionedHashes);
        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidBlobsPublished.selector,
                keccak256(abi.encodePacked(blobVersionedHashes)),
                daCommitment
            )
        );
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_CommittingWithNotPrepublishedBlobs() public {
        bytes32[] memory blobVersionedHashes = new bytes32[](2);
        blobVersionedHashes[0] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;
        blobVersionedHashes[1] = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d6;

        // 2 prepublished blobs
        bytes memory operatorDAInput = abi.encodePacked(blobVersionedHashes[0], blobVersionedHashes[1]);

        bytes32 daCommitment = keccak256(
            abi.encodePacked(
                bytes32(0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5),
                bytes32(0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d6)
            )
        );

        CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;
        correctNewCommitBatchInfo.daCommitmentScheme = L2DACommitmentScheme.BLOBS_ZKSYNC_OS;

        CommitBatchInfoZKsyncOS[] memory correctCommitBatchInfoArray = new CommitBatchInfoZKsyncOS[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, correctCommitBatchInfoArray);

        // with ZKsync OS we have separate pair for blobs
        address blobsl1DaValidatorZKsyncOS = Utils.deployBlobsL1DAValidatorZKsyncOSBytecode();
        vm.prank(address(owner));
        admin.setDAValidatorPair(blobsl1DaValidatorZKsyncOS, L2DACommitmentScheme.BLOBS_ZKSYNC_OS);

        vm.prank(validator);
        vm.expectRevert(BlobNotPublished.selector);
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_BatchNumberMismatch() public {
        bytes memory operatorDAInput = abi.encodePacked(bytes32(0));
        bytes32 daCommitment = bytes32(0);

        CommitBatchInfoZKsyncOS memory wrongBatchInfo = newCommitBatchInfoZKsyncOS;
        wrongBatchInfo.operatorDAInput = operatorDAInput;
        wrongBatchInfo.daCommitment = daCommitment;
        wrongBatchInfo.daCommitmentScheme = L2DACommitmentScheme.EMPTY_NO_DA;
        wrongBatchInfo.batchNumber = 5; // Wrong batch number, should be 1

        CommitBatchInfoZKsyncOS[] memory batchArray = new CommitBatchInfoZKsyncOS[](1);
        batchArray[0] = wrongBatchInfo;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, batchArray);

        address validiumL1DAValidator = address(new ValidiumL1DAValidator());
        vm.prank(address(owner));
        admin.setDAValidatorPair(validiumL1DAValidator, L2DACommitmentScheme.EMPTY_NO_DA);

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSignature("BatchNumberMismatch(uint256,uint256)", 1, 5));
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_IncorrectBatchChainId() public {
        bytes memory operatorDAInput = abi.encodePacked(bytes32(0));
        bytes32 daCommitment = bytes32(0);

        CommitBatchInfoZKsyncOS memory wrongChainBatch = newCommitBatchInfoZKsyncOS;
        wrongChainBatch.operatorDAInput = operatorDAInput;
        wrongChainBatch.daCommitment = daCommitment;
        wrongChainBatch.daCommitmentScheme = L2DACommitmentScheme.EMPTY_NO_DA;
        wrongChainBatch.chainId = 999; // Wrong chain ID

        CommitBatchInfoZKsyncOS[] memory batchArray = new CommitBatchInfoZKsyncOS[](1);
        batchArray[0] = wrongChainBatch;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, batchArray);

        address validiumL1DAValidator = address(new ValidiumL1DAValidator());
        vm.prank(address(owner));
        admin.setDAValidatorPair(validiumL1DAValidator, L2DACommitmentScheme.EMPTY_NO_DA);

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSignature("IncorrectBatchChainId(uint256,uint256)", 999, l2ChainId));
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_IncorrectBatchSLChainId() public {
        bytes memory operatorDAInput = abi.encodePacked(bytes32(0));
        bytes32 daCommitment = bytes32(0);

        CommitBatchInfoZKsyncOS memory wrongChainBatch = newCommitBatchInfoZKsyncOS;
        wrongChainBatch.operatorDAInput = operatorDAInput;
        wrongChainBatch.daCommitment = daCommitment;
        wrongChainBatch.daCommitmentScheme = L2DACommitmentScheme.EMPTY_NO_DA;
        wrongChainBatch.slChainId = 999; // Wrong SL chain ID

        CommitBatchInfoZKsyncOS[] memory batchArray = new CommitBatchInfoZKsyncOS[](1);
        batchArray[0] = wrongChainBatch;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, batchArray);

        address validiumL1DAValidator = address(new ValidiumL1DAValidator());
        vm.prank(address(owner));
        admin.setDAValidatorPair(validiumL1DAValidator, L2DACommitmentScheme.EMPTY_NO_DA);

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSignature("SettlementLayerChainIdMismatch()"));
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_InvalidBlockRange() public {
        bytes memory operatorDAInput = abi.encodePacked(bytes32(0));
        bytes32 daCommitment = bytes32(0);

        CommitBatchInfoZKsyncOS memory invalidBlockBatch = newCommitBatchInfoZKsyncOS;
        invalidBlockBatch.operatorDAInput = operatorDAInput;
        invalidBlockBatch.daCommitment = daCommitment;
        invalidBlockBatch.daCommitmentScheme = L2DACommitmentScheme.EMPTY_NO_DA;
        invalidBlockBatch.firstBlockNumber = 10; // firstBlockNumber > lastBlockNumber
        invalidBlockBatch.lastBlockNumber = 5;

        CommitBatchInfoZKsyncOS[] memory batchArray = new CommitBatchInfoZKsyncOS[](1);
        batchArray[0] = invalidBlockBatch;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, batchArray);

        address validiumL1DAValidator = address(new ValidiumL1DAValidator());
        vm.prank(address(owner));
        admin.setDAValidatorPair(validiumL1DAValidator, L2DACommitmentScheme.EMPTY_NO_DA);

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSignature("InvalidBlockRange(uint64,uint64,uint64)", 1, 10, 5));
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_L2TimestampTooBig() public {
        bytes memory operatorDAInput = abi.encodePacked(bytes32(0));
        bytes32 daCommitment = bytes32(0);

        CommitBatchInfoZKsyncOS memory futureTimestampBatch = newCommitBatchInfoZKsyncOS;
        futureTimestampBatch.operatorDAInput = operatorDAInput;
        futureTimestampBatch.daCommitment = daCommitment;
        futureTimestampBatch.daCommitmentScheme = L2DACommitmentScheme.EMPTY_NO_DA;
        // Set lastBlockTimestamp far in the future
        futureTimestampBatch.lastBlockTimestamp = uint64(block.timestamp + 365 days);

        CommitBatchInfoZKsyncOS[] memory batchArray = new CommitBatchInfoZKsyncOS[](1);
        batchArray[0] = futureTimestampBatch;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, batchArray);

        address validiumL1DAValidator = address(new ValidiumL1DAValidator());
        vm.prank(address(owner));
        admin.setDAValidatorPair(validiumL1DAValidator, L2DACommitmentScheme.EMPTY_NO_DA);

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSignature("L2TimestampTooBig()"));
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_RevertWhen_TimeNotReached() public {
        bytes memory operatorDAInput = abi.encodePacked(bytes32(0));
        bytes32 daCommitment = bytes32(0);

        CommitBatchInfoZKsyncOS memory pastTimestampBatch = newCommitBatchInfoZKsyncOS;
        pastTimestampBatch.operatorDAInput = operatorDAInput;
        pastTimestampBatch.daCommitment = daCommitment;
        pastTimestampBatch.daCommitmentScheme = L2DACommitmentScheme.EMPTY_NO_DA;
        // Set firstBlockTimestamp far in the past
        pastTimestampBatch.firstBlockTimestamp = 1;

        CommitBatchInfoZKsyncOS[] memory batchArray = new CommitBatchInfoZKsyncOS[](1);
        batchArray[0] = pastTimestampBatch;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, batchArray);

        address validiumL1DAValidator = address(new ValidiumL1DAValidator());
        vm.prank(address(owner));
        admin.setDAValidatorPair(validiumL1DAValidator, L2DACommitmentScheme.EMPTY_NO_DA);

        vm.prank(validator);
        vm.expectRevert(); // TimeNotReached error
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    /// @notice Reverts when the batch-level `firstBlockTimestamp` exceeds `lastBlockTimestamp`.
    /// @dev Both timestamps stay inside the [block.timestamp - NOT_OLDER, block.timestamp + DELTA] window
    ///      so that the earlier `TimeNotReached` and `L2TimestampTooBig` checks do not trigger first.
    function test_RevertWhen_FirstBlockTimestampGreaterThanLastBlockTimestamp() public {
        bytes memory operatorDAInput = abi.encodePacked(bytes32(0));
        bytes32 daCommitment = bytes32(0);

        CommitBatchInfoZKsyncOS memory invertedTimestampBatch = newCommitBatchInfoZKsyncOS;
        invertedTimestampBatch.operatorDAInput = operatorDAInput;
        invertedTimestampBatch.daCommitment = daCommitment;
        invertedTimestampBatch.daCommitmentScheme = L2DACommitmentScheme.EMPTY_NO_DA;
        // firstBlockTimestamp > lastBlockTimestamp triggers the new invariant.
        invertedTimestampBatch.firstBlockTimestamp = uint64(currentTimestamp);
        invertedTimestampBatch.lastBlockTimestamp = uint64(currentTimestamp - 1);

        CommitBatchInfoZKsyncOS[] memory batchArray = new CommitBatchInfoZKsyncOS[](1);
        batchArray[0] = invertedTimestampBatch;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, batchArray);

        address validiumL1DAValidator = address(new ValidiumL1DAValidator());
        vm.prank(address(owner));
        admin.setDAValidatorPair(validiumL1DAValidator, L2DACommitmentScheme.EMPTY_NO_DA);

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSignature("BatchTimestampGreaterThanLastL2BlockTimestamp()"));
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    /// @notice Boundary case: `firstBlockTimestamp == lastBlockTimestamp` must still commit successfully,
    ///         because the guard uses a strict `>` comparison.
    function test_SuccessfullyCommit_WhenFirstEqualsLastBlockTimestamp() public {
        bytes memory operatorDAInput = abi.encodePacked(bytes32(0));
        bytes32 daCommitment = bytes32(0);

        CommitBatchInfoZKsyncOS memory equalTimestampBatch = newCommitBatchInfoZKsyncOS;
        equalTimestampBatch.operatorDAInput = operatorDAInput;
        equalTimestampBatch.daCommitment = daCommitment;
        equalTimestampBatch.daCommitmentScheme = L2DACommitmentScheme.EMPTY_NO_DA;
        // Pick a value strictly inside the valid window and set both bounds equal.
        uint64 equalTs = uint64(currentTimestamp - 5);
        equalTimestampBatch.firstBlockTimestamp = equalTs;
        equalTimestampBatch.lastBlockTimestamp = equalTs;

        CommitBatchInfoZKsyncOS[] memory batchArray = new CommitBatchInfoZKsyncOS[](1);
        batchArray[0] = equalTimestampBatch;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, batchArray);

        address validiumL1DAValidator = address(new ValidiumL1DAValidator());
        vm.prank(address(owner));
        admin.setDAValidatorPair(validiumL1DAValidator, L2DACommitmentScheme.EMPTY_NO_DA);

        vm.prank(validator);
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    /// @notice Fuzz: any batch with `firstBlockTimestamp > lastBlockTimestamp` must revert with the
    ///         new error. Inputs are bounded to keep other timestamp guards from firing first.
    function testFuzz_RevertWhen_FirstBlockTimestampGreaterThanLastBlockTimestamp(
        uint64 firstTs,
        uint64 lastTs
    ) public {
        // Keep both timestamps inside the valid commit window so they only fail the new check.
        firstTs = uint64(bound(uint256(firstTs), currentTimestamp - 10, currentTimestamp));
        lastTs = uint64(bound(uint256(lastTs), currentTimestamp - 10, currentTimestamp));
        // Enforce strict inversion; abandon degenerate inputs by rejecting them.
        vm.assume(firstTs > lastTs);

        bytes memory operatorDAInput = abi.encodePacked(bytes32(0));
        bytes32 daCommitment = bytes32(0);

        CommitBatchInfoZKsyncOS memory invertedTimestampBatch = newCommitBatchInfoZKsyncOS;
        invertedTimestampBatch.operatorDAInput = operatorDAInput;
        invertedTimestampBatch.daCommitment = daCommitment;
        invertedTimestampBatch.daCommitmentScheme = L2DACommitmentScheme.EMPTY_NO_DA;
        invertedTimestampBatch.firstBlockTimestamp = firstTs;
        invertedTimestampBatch.lastBlockTimestamp = lastTs;

        CommitBatchInfoZKsyncOS[] memory batchArray = new CommitBatchInfoZKsyncOS[](1);
        batchArray[0] = invertedTimestampBatch;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, batchArray);

        address validiumL1DAValidator = address(new ValidiumL1DAValidator());
        vm.prank(address(owner));
        admin.setDAValidatorPair(validiumL1DAValidator, L2DACommitmentScheme.EMPTY_NO_DA);

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSignature("BatchTimestampGreaterThanLastL2BlockTimestamp()"));
        committer.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }
}
