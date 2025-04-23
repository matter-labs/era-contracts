// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Utils} from "../../Utils/Utils.sol";
import {TestCalldataDA} from "contracts/dev-contracts/test/TestCalldataDA.sol";
import {BLOB_SIZE_BYTES, BLOB_DATA_OFFSET, BLOB_COMMITMENT_SIZE} from "contracts/state-transition/data-availability/CalldataDA.sol";
import {OperatorDAInputTooSmall, InvalidNumberOfBlobs, InvalidL2DAOutputHash, OnlyOneBlobWithCalldataAllowed, PubdataInputTooSmall, PubdataLengthTooBig, InvalidPubdataHash} from "contracts/state-transition/L1StateTransitionErrors.sol";

contract CalldataDATest is Test {
    TestCalldataDA calldataDA;

    function setUp() public {
        calldataDA = new TestCalldataDA();
    }

    /*//////////////////////////////////////////////////////////////////////////
                    CalldataDA::_processL2RollupDAValidatorOutputHash
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_OperatorInputTooSmall() public {
        bytes32 l2DAValidatorOutputHash = Utils.randomBytes32("l2DAValidatorOutputHash");
        uint256 maxBlobsSupported = 1;
        bytes memory operatorDAInput = hex"";

        vm.expectRevert(
            abi.encodeWithSelector(OperatorDAInputTooSmall.selector, operatorDAInput.length, BLOB_DATA_OFFSET)
        );
        calldataDA.processL2RollupDAValidatorOutputHash(l2DAValidatorOutputHash, maxBlobsSupported, operatorDAInput);
    }

    function test_RevertWhen_InvalidNumberOfBlobs() public {
        bytes32 l2DAValidatorOutputHash = Utils.randomBytes32("l2DAValidatorOutputHash");
        uint256 maxBlobsSupported = 1;

        bytes32 stateDiffHash = Utils.randomBytes32("stateDiffHash");
        bytes32 fullPubdataHash = Utils.randomBytes32("fullPubdataHash");
        uint8 blobsProvided = 8;

        bytes memory operatorDAInput = abi.encodePacked(stateDiffHash, fullPubdataHash, blobsProvided);

        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidNumberOfBlobs.selector,
                uint256(uint8(operatorDAInput[64])),
                maxBlobsSupported
            )
        );
        calldataDA.processL2RollupDAValidatorOutputHash(l2DAValidatorOutputHash, maxBlobsSupported, operatorDAInput);
    }

    function test_RevertWhen_InvalidBlobHashes() public {
        bytes32 l2DAValidatorOutputHash = Utils.randomBytes32("l2DAValidatorOutputHash");
        uint256 maxBlobsSupported = 1;

        bytes32 stateDiffHash = Utils.randomBytes32("stateDiffHash");
        bytes32 fullPubdataHash = Utils.randomBytes32("fullPubdataHash");
        uint8 blobsProvided = 1;

        bytes memory operatorDAInput = abi.encodePacked(stateDiffHash, fullPubdataHash, blobsProvided);

        vm.expectRevert(
            abi.encodeWithSelector(
                OperatorDAInputTooSmall.selector,
                operatorDAInput.length,
                BLOB_DATA_OFFSET + 32 * uint256(uint8(operatorDAInput[64]))
            )
        );
        calldataDA.processL2RollupDAValidatorOutputHash(l2DAValidatorOutputHash, maxBlobsSupported, operatorDAInput);
    }

    function test_RevertWhen_InvaliL2DAOutputHash() public {
        bytes32 l2DAValidatorOutputHash = Utils.randomBytes32("l2DAValidatorOutputHash");
        uint256 maxBlobsSupported = 1;

        bytes32 stateDiffHash = Utils.randomBytes32("stateDiffHash");
        bytes32 fullPubdataHash = Utils.randomBytes32("fullPubdataHash");
        uint8 blobsProvided = 1;
        bytes32 blobLinearHash = Utils.randomBytes32("blobLinearHash");

        bytes memory operatorDAInput = abi.encodePacked(stateDiffHash, fullPubdataHash, blobsProvided, blobLinearHash);

        vm.expectRevert(abi.encodeWithSelector(InvalidL2DAOutputHash.selector, l2DAValidatorOutputHash));
        calldataDA.processL2RollupDAValidatorOutputHash(l2DAValidatorOutputHash, maxBlobsSupported, operatorDAInput);
    }

    function test_ProcessL2RollupDAValidatorOutputHash() public {
        bytes32 stateDiffHash = Utils.randomBytes32("stateDiffHash");
        bytes32 fullPubdataHash = Utils.randomBytes32("fullPubdataHash");
        uint8 blobsProvided = 1;
        bytes32 blobLinearHash = Utils.randomBytes32("blobLinearHash");

        bytes memory daInput = abi.encodePacked(stateDiffHash, fullPubdataHash, blobsProvided, blobLinearHash);
        bytes memory l1DaInput = "verifydonttrust";

        bytes32 l2DAValidatorOutputHash = keccak256(daInput);

        bytes memory operatorDAInput = abi.encodePacked(daInput, l1DaInput);

        (
            bytes32 outputStateDiffHash,
            bytes32 outputFullPubdataHash,
            bytes32[] memory blobsLinearHashes,
            uint256 outputBlobsProvided,
            bytes memory outputL1DaInput
        ) = calldataDA.processL2RollupDAValidatorOutputHash(l2DAValidatorOutputHash, blobsProvided, operatorDAInput);

        assertEq(outputStateDiffHash, stateDiffHash, "stateDiffHash");
        assertEq(outputFullPubdataHash, fullPubdataHash, "fullPubdataHash");
        assertEq(blobsLinearHashes.length, 1, "blobsLinearHashesLength");
        assertEq(blobsLinearHashes[0], blobLinearHash, "blobsLinearHashes");
        assertEq(outputL1DaInput, l1DaInput, "l1DaInput");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            CalldataDA::_processCalldataDA
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_OnlyOneBlobWithCalldataAllowed(uint256 blobsProvided) public {
        vm.assume(blobsProvided != 1);
        bytes32 fullPubdataHash = Utils.randomBytes32("fullPubdataHash");
        uint256 maxBlobsSupported = 6;
        bytes memory pubdataInput = "";

        vm.expectRevert(OnlyOneBlobWithCalldataAllowed.selector);
        calldataDA.processCalldataDA(blobsProvided, fullPubdataHash, maxBlobsSupported, pubdataInput);
    }

    function test_RevertWhen_PubdataTooBig() public {
        uint256 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes calldata pubdataInput = makeBytesArrayOfLength(BLOB_SIZE_BYTES + 33);
        bytes32 fullPubdataHash = keccak256(pubdataInput);

        vm.expectRevert(abi.encodeWithSelector(PubdataLengthTooBig.selector, 126977, blobsProvided * BLOB_SIZE_BYTES));
        calldataDA.processCalldataDA(blobsProvided, fullPubdataHash, maxBlobsSupported, pubdataInput);
    }

    function test_RevertWhen_PubdataInputTooSmall() public {
        uint256 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes calldata pubdataInput = makeBytesArrayOfLength(31);
        bytes32 fullPubdataHash = keccak256(pubdataInput);

        vm.expectRevert(
            abi.encodeWithSelector(PubdataInputTooSmall.selector, pubdataInput.length, BLOB_COMMITMENT_SIZE)
        );
        calldataDA.processCalldataDA(blobsProvided, fullPubdataHash, maxBlobsSupported, pubdataInput);
    }

    function test_RevertWhen_PubdataDoesntMatchPubdataHash() public {
        uint256 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes memory pubdataInputWithoutBlobCommitment = "verifydonttrustzkistheendgamemagicmoonmath";
        bytes32 blobCommitment = Utils.randomBytes32("blobCommitment");
        bytes memory pubdataInput = abi.encodePacked(pubdataInputWithoutBlobCommitment, blobCommitment);
        bytes32 fullPubdataHash = keccak256(pubdataInput);

        vm.expectRevert(
            abi.encodeWithSelector(
                InvalidPubdataHash.selector,
                fullPubdataHash,
                keccak256(pubdataInputWithoutBlobCommitment)
            )
        );
        calldataDA.processCalldataDA(blobsProvided, fullPubdataHash, maxBlobsSupported, pubdataInput);
    }

    function test_ProcessCalldataDA() public {
        uint256 blobsProvided = 1;
        uint256 maxBlobsSupported = 6;
        bytes memory pubdataInputWithoutBlobCommitment = "verifydonttrustzkistheendgamemagicmoonmath";
        bytes32 blobCommitment = Utils.randomBytes32("blobCommitment");
        bytes memory pubdataInput = abi.encodePacked(pubdataInputWithoutBlobCommitment, blobCommitment);
        bytes32 fullPubdataHash = keccak256(pubdataInputWithoutBlobCommitment);

        (bytes32[] memory blobCommitments, bytes memory pubdata) = calldataDA.processCalldataDA(
            blobsProvided,
            fullPubdataHash,
            maxBlobsSupported,
            pubdataInput
        );

        assertEq(blobCommitments.length, 6, "blobCommitmentsLength");
        assertEq(blobCommitments[0], blobCommitment, "blobCommitment1");
        assertEq(blobCommitments[1], bytes32(0), "blobCommitment2");
        assertEq(blobCommitments[2], bytes32(0), "blobCommitment3");
        assertEq(blobCommitments[3], bytes32(0), "blobCommitment4");
        assertEq(blobCommitments[4], bytes32(0), "blobCommitment5");
        assertEq(blobCommitments[5], bytes32(0), "blobCommitment6");
        assertEq(pubdata, pubdataInputWithoutBlobCommitment, "pubdata");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    Util Functions
    //////////////////////////////////////////////////////////////////////////*/

    function makeBytesArrayOfLength(uint256 len) internal returns (bytes calldata arr) {
        assembly {
            arr.length := len
        }
    }
}
