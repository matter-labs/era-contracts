// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {RollupL1DAValidator} from "contracts/state-transition/data-availability/RollupL1DAValidator.sol";
import {L1DAValidatorOutput, PubdataSource} from "contracts/state-transition/chain-interfaces/IL1DAValidator.sol";
import {
    BLOB_EXPIRATION_BLOCKS,
    BLS_MODULUS,
    POINT_EVALUATION_PRECOMPILE_ADDR
} from "contracts/state-transition/data-availability/DAConstants.sol";
import {InvalidPubdataSource} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {
    BlobCommitmentNotPublished,
    BlobHashCommitmentError,
    EmptyBlobVersionHash,
    InvalidPubdataCommitmentsSize,
    NonEmptyBlobVersionHash,
    PointEvalCallFailed,
    PointEvalFailed,
    PubdataCommitmentsEmpty
} from "contracts/state-transition/data-availability/DAErrors.sol";

contract RollupL1DAValidatorTest is Test {
    RollupL1DAValidator internal validator;

    bytes32 internal constant STATE_DIFF_HASH = keccak256("stateDiffHash");
    bytes32 internal constant VERSIONED_HASH_1 = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d5;
    bytes32 internal constant VERSIONED_HASH_2 = 0x01c024b4740620a5849f95930cefe298933bdf588123ea897cdf0f2462f6d2d6;

    function setUp() public {
        validator = new RollupL1DAValidator();
        _mockPointEvaluation(BLS_MODULUS);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Helpers
    //////////////////////////////////////////////////////////////////////////*/

    function _mockPointEvaluation(uint256 _result) internal {
        vm.mockCall(POINT_EVALUATION_PRECOMPILE_ADDR, bytes(""), abi.encode(uint256(4096), _result));
    }

    function _setBlobHashes(bytes32 _first, bytes32 _second) internal {
        uint256 len = _second == bytes32(0) ? 1 : 2;
        bytes32[] memory hashes = new bytes32[](len);
        hashes[0] = _first;
        if (len == 2) {
            hashes[1] = _second;
        }
        vm.blobhashes(hashes);
    }

    /// @dev opening point (16 bytes) || claimed value (32 bytes) || commitment (48 bytes) || proof (48 bytes)
    function _pubdataCommitment(uint256 _seed) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                _openingPoint(_seed),
                _claimedValue(_seed),
                keccak256(abi.encode("commitment", _seed)),
                bytes16(keccak256(abi.encode("commitmentTail", _seed))),
                keccak256(abi.encode("proof", _seed)),
                bytes16(keccak256(abi.encode("proofTail", _seed)))
            );
    }

    function _openingPoint(uint256 _seed) internal pure returns (bytes16) {
        return bytes16(keccak256(abi.encode("openingPoint", _seed)));
    }

    function _claimedValue(uint256 _seed) internal pure returns (bytes32) {
        return keccak256(abi.encode("claimedValue", _seed));
    }

    function _expectedBlobCommitment(bytes32 _versionedHash, uint256 _seed) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_versionedHash, _openingPoint(_seed), _claimedValue(_seed)));
    }

    /// @dev Builds the operator DA input and the L2 DA validator output hash it commits to.
    function _operatorDAInput(
        bytes32 _fullPubdataHash,
        bytes32[] memory _linearHashes,
        bytes memory _l1DaInput
    ) internal pure returns (bytes32 l2DAValidatorOutputHash, bytes memory operatorDAInput) {
        bytes memory header = abi.encodePacked(STATE_DIFF_HASH, _fullPubdataHash, uint8(_linearHashes.length));
        for (uint256 i = 0; i < _linearHashes.length; ++i) {
            header = bytes.concat(header, _linearHashes[i]);
        }
        l2DAValidatorOutputHash = keccak256(header);
        operatorDAInput = bytes.concat(header, _l1DaInput);
    }

    function _twoLinearHashes() internal pure returns (bytes32[] memory linearHashes) {
        linearHashes = new bytes32[](2);
        linearHashes[0] = keccak256("linearHash1");
        linearHashes[1] = keccak256("linearHash2");
    }

    function _publish(bytes32 _versionedHash, uint256 _seed) internal returns (bytes32 commitment) {
        _setBlobHashes(_versionedHash, bytes32(0));
        validator.publishBlobs(_pubdataCommitment(_seed));
        vm.blobhashes(new bytes32[](0));
        commitment = _expectedBlobCommitment(_versionedHash, _seed);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    publishBlobs
    //////////////////////////////////////////////////////////////////////////*/

    function test_publishBlobs_RevertWhen_Empty() public {
        vm.expectRevert(PubdataCommitmentsEmpty.selector);
        validator.publishBlobs("");
    }

    function test_publishBlobs_RevertWhen_InvalidSize() public {
        vm.expectRevert(InvalidPubdataCommitmentsSize.selector);
        validator.publishBlobs(new bytes(143));
    }

    function test_publishBlobs_RevertWhen_NoBlobInTransaction() public {
        vm.expectRevert(abi.encodeWithSelector(EmptyBlobVersionHash.selector, 0));
        validator.publishBlobs(_pubdataCommitment(1));
    }

    function test_publishBlobs_RevertWhen_PointEvaluationCallFails() public {
        bytes memory commitment = _pubdataCommitment(1);
        _setBlobHashes(VERSIONED_HASH_1, bytes32(0));
        vm.mockCallRevert(POINT_EVALUATION_PRECOMPILE_ADDR, bytes(""), "");

        bytes memory openingValueCommitmentProof = new bytes(128);
        for (uint256 i = 0; i < 128; ++i) {
            openingValueCommitmentProof[i] = commitment[16 + i];
        }
        bytes memory precompileInput = abi.encodePacked(
            VERSIONED_HASH_1,
            bytes32(uint256(uint128(_openingPoint(1)))),
            openingValueCommitmentProof
        );

        vm.expectRevert(abi.encodeWithSelector(PointEvalCallFailed.selector, precompileInput));
        validator.publishBlobs(commitment);
    }

    function test_publishBlobs_RevertWhen_PointEvaluationFails() public {
        _setBlobHashes(VERSIONED_HASH_1, bytes32(0));
        _mockPointEvaluation(1);

        vm.expectRevert(abi.encodeWithSelector(PointEvalFailed.selector, abi.encode(uint256(1))));
        validator.publishBlobs(_pubdataCommitment(1));
    }

    function test_publishBlobs_StoresCommitments() public {
        _setBlobHashes(VERSIONED_HASH_1, VERSIONED_HASH_2);
        validator.publishBlobs(bytes.concat(_pubdataCommitment(1), _pubdataCommitment(2)));

        bytes32 commitment1 = _expectedBlobCommitment(VERSIONED_HASH_1, 1);
        bytes32 commitment2 = _expectedBlobCommitment(VERSIONED_HASH_2, 2);
        assertEq(validator.publishedBlobCommitments(commitment1), block.number);
        assertEq(validator.publishedBlobCommitments(commitment2), block.number);
        assertTrue(validator.isBlobAvailable(commitment1));
        assertTrue(validator.isBlobAvailable(commitment2));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    isBlobAvailable
    //////////////////////////////////////////////////////////////////////////*/

    function test_isBlobAvailable_FalseWhenNotPublished() public view {
        assertFalse(validator.isBlobAvailable(keccak256("unknown")));
    }

    function test_isBlobAvailable_Expires() public {
        bytes32 commitment = _publish(VERSIONED_HASH_1, 1);

        vm.roll(block.number + BLOB_EXPIRATION_BLOCKS);
        assertTrue(validator.isBlobAvailable(commitment));

        vm.roll(block.number + 1);
        assertFalse(validator.isBlobAvailable(commitment));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                checkDA: calldata
    //////////////////////////////////////////////////////////////////////////*/

    function test_checkDA_Calldata() public view {
        bytes memory pubdata = "pubdata";
        bytes32 blobCommitment = keccak256("blobCommitment");
        bytes32[] memory linearHashes = new bytes32[](1);
        linearHashes[0] = keccak256("linearHash");
        (bytes32 outputHash, bytes memory input) = _operatorDAInput(
            keccak256(pubdata),
            linearHashes,
            abi.encodePacked(uint8(PubdataSource.Calldata), pubdata, blobCommitment)
        );

        // solhint-disable-next-line func-named-parameters
        L1DAValidatorOutput memory output = validator.checkDA(1, 1, outputHash, input, 2);

        assertEq(output.stateDiffHash, STATE_DIFF_HASH);
        assertEq(output.blobsLinearHashes.length, 2);
        assertEq(output.blobsLinearHashes[0], linearHashes[0]);
        assertEq(output.blobsLinearHashes[1], bytes32(0));
        assertEq(output.blobsOpeningCommitments.length, 2);
        assertEq(output.blobsOpeningCommitments[0], blobCommitment);
        assertEq(output.blobsOpeningCommitments[1], bytes32(0));
    }

    function test_checkDA_RevertWhen_CommitmentWithoutLinearHash() public {
        bytes memory pubdata = "pubdata";
        bytes32[] memory linearHashes = new bytes32[](1);
        (bytes32 outputHash, bytes memory input) = _operatorDAInput(
            keccak256(pubdata),
            linearHashes,
            abi.encodePacked(uint8(PubdataSource.Calldata), pubdata, keccak256("blobCommitment"))
        );

        vm.expectRevert(abi.encodeWithSelector(BlobHashCommitmentError.selector, 0, true, false));
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, outputHash, input, 1);
    }

    function test_checkDA_RevertWhen_LinearHashWithoutCommitment() public {
        bytes memory pubdata = "pubdata";
        bytes32[] memory linearHashes = new bytes32[](1);
        linearHashes[0] = keccak256("linearHash");
        (bytes32 outputHash, bytes memory input) = _operatorDAInput(
            keccak256(pubdata),
            linearHashes,
            abi.encodePacked(uint8(PubdataSource.Calldata), pubdata, bytes32(0))
        );

        vm.expectRevert(abi.encodeWithSelector(BlobHashCommitmentError.selector, 0, false, true));
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, outputHash, input, 1);
    }

    function test_checkDA_RevertWhen_InvalidPubdataSource() public {
        (bytes32 outputHash, bytes memory input) = _operatorDAInput(
            bytes32(0),
            new bytes32[](0),
            abi.encodePacked(uint8(2))
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidPubdataSource.selector, uint8(2)));
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, outputHash, input, 1);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                checkDA: blobs
    //////////////////////////////////////////////////////////////////////////*/

    function test_checkDA_BlobsPublishedInSameTransaction() public {
        bytes32[] memory linearHashes = _twoLinearHashes();
        (bytes32 outputHash, bytes memory input) = _operatorDAInput(
            bytes32(0),
            linearHashes,
            abi.encodePacked(
                uint8(PubdataSource.Blob),
                _pubdataCommitment(1),
                bytes32(0),
                _pubdataCommitment(2),
                bytes32(0)
            )
        );
        _setBlobHashes(VERSIONED_HASH_1, VERSIONED_HASH_2);

        // solhint-disable-next-line func-named-parameters
        L1DAValidatorOutput memory output = validator.checkDA(1, 1, outputHash, input, 3);

        assertEq(output.stateDiffHash, STATE_DIFF_HASH);
        assertEq(output.blobsLinearHashes.length, 3);
        assertEq(output.blobsLinearHashes[0], linearHashes[0]);
        assertEq(output.blobsLinearHashes[1], linearHashes[1]);
        assertEq(output.blobsLinearHashes[2], bytes32(0));
        assertEq(output.blobsOpeningCommitments.length, 3);
        assertEq(output.blobsOpeningCommitments[0], _expectedBlobCommitment(VERSIONED_HASH_1, 1));
        assertEq(output.blobsOpeningCommitments[1], _expectedBlobCommitment(VERSIONED_HASH_2, 2));
        assertEq(output.blobsOpeningCommitments[2], bytes32(0));
    }

    function test_checkDA_PrepublishedAndNewBlob() public {
        bytes32 prepublished = _publish(VERSIONED_HASH_1, 1);

        bytes32[] memory linearHashes = _twoLinearHashes();
        (bytes32 outputHash, bytes memory input) = _operatorDAInput(
            bytes32(0),
            linearHashes,
            abi.encodePacked(uint8(PubdataSource.Blob), new bytes(144), prepublished, _pubdataCommitment(2), bytes32(0))
        );
        // The prepublished blob doesn't consume a blob of this transaction.
        _setBlobHashes(VERSIONED_HASH_2, bytes32(0));

        // solhint-disable-next-line func-named-parameters
        L1DAValidatorOutput memory output = validator.checkDA(1, 1, outputHash, input, 2);

        assertEq(output.blobsOpeningCommitments[0], prepublished);
        assertEq(output.blobsOpeningCommitments[1], _expectedBlobCommitment(VERSIONED_HASH_2, 2));
    }

    function test_checkDA_RevertWhen_PrepublishedBlobNotPublished() public {
        bytes32[] memory linearHashes = new bytes32[](1);
        linearHashes[0] = keccak256("linearHash");
        (bytes32 outputHash, bytes memory input) = _operatorDAInput(
            bytes32(0),
            linearHashes,
            abi.encodePacked(uint8(PubdataSource.Blob), new bytes(144), keccak256("notPublished"))
        );

        vm.expectRevert(BlobCommitmentNotPublished.selector);
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, outputHash, input, 1);
    }

    function test_checkDA_RevertWhen_PrepublishedBlobExpired() public {
        bytes32 prepublished = _publish(VERSIONED_HASH_1, 1);
        vm.roll(block.number + BLOB_EXPIRATION_BLOCKS + 1);

        bytes32[] memory linearHashes = new bytes32[](1);
        linearHashes[0] = keccak256("linearHash");
        (bytes32 outputHash, bytes memory input) = _operatorDAInput(
            bytes32(0),
            linearHashes,
            abi.encodePacked(uint8(PubdataSource.Blob), new bytes(144), prepublished)
        );

        vm.expectRevert(BlobCommitmentNotPublished.selector);
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, outputHash, input, 1);
    }

    function test_checkDA_RevertWhen_ExtraBlobInTransaction() public {
        bytes32[] memory linearHashes = new bytes32[](1);
        linearHashes[0] = keccak256("linearHash");
        (bytes32 outputHash, bytes memory input) = _operatorDAInput(
            bytes32(0),
            linearHashes,
            abi.encodePacked(uint8(PubdataSource.Blob), _pubdataCommitment(1), bytes32(0))
        );
        _setBlobHashes(VERSIONED_HASH_1, VERSIONED_HASH_2);

        vm.expectRevert(abi.encodeWithSelector(NonEmptyBlobVersionHash.selector, 1));
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, outputHash, input, 1);
    }

    function test_checkDA_RevertWhen_InvalidBlobInputLength() public {
        bytes32[] memory linearHashes = new bytes32[](1);
        linearHashes[0] = keccak256("linearHash");
        (bytes32 outputHash, bytes memory input) = _operatorDAInput(
            bytes32(0),
            linearHashes,
            abi.encodePacked(uint8(PubdataSource.Blob), _pubdataCommitment(1))
        );

        vm.expectRevert(InvalidPubdataCommitmentsSize.selector);
        // solhint-disable-next-line func-named-parameters
        validator.checkDA(1, 1, outputHash, input, 1);
    }
}
