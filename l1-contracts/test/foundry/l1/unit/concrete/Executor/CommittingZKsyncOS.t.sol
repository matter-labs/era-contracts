// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/console.sol";
import {Vm} from "forge-std/Test.sol";
import {Utils} from "../Utils/Utils.sol";
import {ExecutorTest} from "./_Executor_Shared.t.sol";

import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {MismatchL2DACommitmentScheme} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {ValidiumL1DAValidator} from "contracts/state-transition/data-availability/ValidiumL1DAValidator.sol";
import {InvalidPubdataHash, InvalidBlobsPublished, BlobNotPublished} from "../../../da-contracts-imports/DAContractsErrors.sol";
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

        IExecutor.CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;

        IExecutor.CommitBatchInfoZKsyncOS[]
            memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfoZKsyncOS[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, correctCommitBatchInfoArray);
        vm.prank(validator);
        executor.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
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

        IExecutor.CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;
        correctNewCommitBatchInfo.daCommitmentScheme = L2DACommitmentScheme.BLOBS_ZKSYNC_OS;

        IExecutor.CommitBatchInfoZKsyncOS[]
            memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfoZKsyncOS[](1);
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
        executor.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
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

        IExecutor.CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;
        correctNewCommitBatchInfo.daCommitmentScheme = L2DACommitmentScheme.BLOBS_ZKSYNC_OS;

        IExecutor.CommitBatchInfoZKsyncOS[]
            memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfoZKsyncOS[](1);
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
        executor.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }

    function test_SuccessfullyCommitBatchValidium() public {
        bytes memory operatorDAInput = abi.encodePacked(
            bytes32(0) // just put zero with zksync os, no need to verify it
        );

        bytes32 daCommitment = bytes32(0); // empty

        IExecutor.CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;
        correctNewCommitBatchInfo.daCommitmentScheme = L2DACommitmentScheme.EMPTY_NO_DA;

        IExecutor.CommitBatchInfoZKsyncOS[]
            memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfoZKsyncOS[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, correctCommitBatchInfoArray);

        // with ZKsync OS we have separate pair for blobs
        address validiumL1DAValidator = address(new ValidiumL1DAValidator());
        vm.prank(address(owner));
        admin.setDAValidatorPair(validiumL1DAValidator, L2DACommitmentScheme.EMPTY_NO_DA);

        vm.prank(validator);
        executor.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
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

        IExecutor.CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;
        correctNewCommitBatchInfo.daCommitmentScheme = L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256;

        IExecutor.CommitBatchInfoZKsyncOS[]
            memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfoZKsyncOS[](1);
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
        executor.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
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

        IExecutor.CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;

        IExecutor.CommitBatchInfoZKsyncOS[]
            memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfoZKsyncOS[](1);
        correctCommitBatchInfoArray[0] = correctNewCommitBatchInfo;
        correctCommitBatchInfoArray[0].operatorDAInput = operatorDAInput;

        (uint256 commitBatchFrom, uint256 commitBatchTo, bytes memory commitData) = Utils
            .encodeCommitBatchesDataZKsyncOS(genesisStoredBatchInfo, correctCommitBatchInfoArray);
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(InvalidPubdataHash.selector, totalL2PubdataHash, keccak256(pubdata)));
        executor.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
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

        IExecutor.CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;
        correctNewCommitBatchInfo.daCommitmentScheme = L2DACommitmentScheme.BLOBS_ZKSYNC_OS;

        IExecutor.CommitBatchInfoZKsyncOS[]
            memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfoZKsyncOS[](1);
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
        executor.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
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

        IExecutor.CommitBatchInfoZKsyncOS memory correctNewCommitBatchInfo = newCommitBatchInfoZKsyncOS;
        correctNewCommitBatchInfo.operatorDAInput = operatorDAInput;
        correctNewCommitBatchInfo.daCommitment = daCommitment;
        correctNewCommitBatchInfo.daCommitmentScheme = L2DACommitmentScheme.BLOBS_ZKSYNC_OS;

        IExecutor.CommitBatchInfoZKsyncOS[]
            memory correctCommitBatchInfoArray = new IExecutor.CommitBatchInfoZKsyncOS[](1);
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
        executor.commitBatchesSharedBridge(address(0), commitBatchFrom, commitBatchTo, commitData);
    }
}
