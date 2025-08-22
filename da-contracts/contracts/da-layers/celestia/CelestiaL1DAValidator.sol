// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IL1DAValidator, L1DAValidatorOutput} from "../../IL1DAValidator.sol";
import {IDAOracle} from "./IDAOracle.sol";
import {ISP1Verifier} from "./ISP1Verifier.sol";
import {CelestiaZKStackInput, CelestiaTooManyBlobs, CelestiaInvalidPublicValuesLength, CelestiaBatchNumberMismatch, CelestiaChainIdMismatch} from "./types.sol";

contract CelestiaL1DAValidator is IL1DAValidator {
    error InvalidProof();
    error OperatorDAHashMismatch(bytes32 expected, bytes32 actual);
    error DataRootMismatch(bytes32 expected, bytes32 actual);

    address public immutable SP1_GROTH_16_VERIFIER;
    address public immutable BLOBSTREAM;
    bytes32 public immutable eqsVkey;

    constructor(address _sp1Groth16Verifier, address _blobstream, bytes32 _eqsVkey) {
        SP1_GROTH_16_VERIFIER = _sp1Groth16Verifier;
        BLOBSTREAM = _blobstream;
        eqsVkey = _eqsVkey;
    }

    function checkDA(
        uint256 chainId,
        uint256 batchNumber,
        bytes32 l2DAValidatorOutputHash,
        bytes calldata operatorDAInput,
        uint256 _maxBlobsSupported
    ) external view returns (L1DAValidatorOutput memory output) {
        // _maxBlobsSupported is unused by the Celestia integration
        // just to be safe, we enforce a maximum to prevent accidental failures due to misconfiguration.
        // see audit issue N-01
        if (_maxBlobsSupported > 256) revert CelestiaTooManyBlobs(_maxBlobsSupported);

        CelestiaZKStackInput memory input = abi.decode(operatorDAInput[32:], (CelestiaZKStackInput));

        bytes memory publicValues = input.publicValues; // get reference to bytes
        bytes32 eqKeccakHash;
        bytes32 eqDataRoot;
        uint32 eqBatchNumber;
        uint64 eqChainId;
        // The public values must be exactly 4 x 32 bytes for keccak hash, data root, batch number, and chain id
        if (publicValues.length != 76) revert CelestiaInvalidPublicValuesLength(publicValues.length);
        assembly {
            let ptr := add(publicValues, 32) // skip length prefix
            eqKeccakHash := mload(ptr) // first bytes32
            eqDataRoot := mload(add(ptr, 32)) // second bytes32
            eqBatchNumber := shr(224, mload(add(ptr, 64))) // third bytes32, but we only want the last 4 bytes (u32)
            eqChainId := shr(192, mload(add(ptr, 96))) // fourth bytes32, but we only want the last 8 bytes (u64)
        }

        // Verify that the batch number and chain ID match the values in the equivalence proof
        if (batchNumber != eqBatchNumber) revert CelestiaBatchNumberMismatch(batchNumber, eqBatchNumber);
        if (chainId != eqChainId) revert CelestiaChainIdMismatch(chainId, eqChainId);

        // First verify the equivalency proof using low-level staticcall
        (bool success, bytes memory returnData) = SP1_GROTH_16_VERIFIER.staticcall(
            abi.encodeWithSelector(
                ISP1Verifier.verifyProof.selector,
                eqsVkey,
                input.publicValues,
                input.equivalenceProof
            )
        );

        // Check if the call was successful and didn't revert
        if (!success) {
            // If returnData is empty, it means the call reverted
            if (returnData.length == 0) {
                revert InvalidProof();
            }
            // If returnData is not empty, it contains the revert reason
            assembly {
                let returndata_size := mload(returnData)
                revert(add(32, returnData), returndata_size)
            }
        }

        // lastly we verify the data root is inside of blobstream
        bool valid = IDAOracle(BLOBSTREAM).verifyAttestation(
            input.attestationProof.tupleRootNonce,
            input.attestationProof.tuple,
            input.attestationProof.proof
        );

        // can use custom error or whatever matter labs likes the most
        if (!valid) revert InvalidProof();

        output.stateDiffHash = bytes32(operatorDAInput[:32]);

        if (l2DAValidatorOutputHash != keccak256(abi.encodePacked(output.stateDiffHash, eqKeccakHash)))
            revert OperatorDAHashMismatch(
                l2DAValidatorOutputHash,
                keccak256(abi.encodePacked(output.stateDiffHash, eqKeccakHash))
            );
        if (input.attestationProof.tuple.dataRoot != eqDataRoot)
            revert DataRootMismatch(eqDataRoot, input.attestationProof.tuple.dataRoot);

        output.blobsLinearHashes = new bytes32[](_maxBlobsSupported);
        output.blobsOpeningCommitments = new bytes32[](_maxBlobsSupported);
    }
}
