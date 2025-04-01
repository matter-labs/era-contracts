pragma solidity 0.8.24;

import {IL1DAValidator, L1DAValidatorOutput} from "../../IL1DAValidator.sol";
import {IDAOracle} from "./IDAOracle.sol";
import {ISP1Verifier} from "./ISP1Verifier.sol";
import {CelestiaZKStackInput} from "./types.sol";

contract CelestiaL1DAValidator is IL1DAValidator {
    error InvalidProof();
    error OperatorDAHashMismatch(bytes32 expected, bytes32 actual);
    error DataRootMismatch(bytes32 expected, bytes32 actual);

    address public immutable SP1_GROTH_16_VERIFIER;
    address public immutable BLOBSTREAM;
    bytes32 public immutable eqsVkey;

    constructor(
        address _sp1Groth16Verifier,
        address _blobstream,
        bytes32 _eqsVkey
    ) {
        SP1_GROTH_16_VERIFIER = _sp1Groth16Verifier;
        BLOBSTREAM = _blobstream;
        eqsVkey = _eqsVkey;
    }

    function checkDA(
        uint256 chainId,
        uint256 batchNumber,
        bytes32 l2DAValidatorOutputHash,
        bytes calldata _operatorDAInput,
        uint256 _maxBlobsSupported
    ) external returns (L1DAValidatorOutput memory output) {
        CelestiaZKStackInput memory input = abi.decode(_operatorDAInput, (CelestiaZKStackInput));

        bytes memory publicValues = input.publicValues;  // get reference to bytes
        bytes32 eqKeccakHash;
        bytes32 eqDataRoot;
        assembly {
            let ptr := add(publicValues, 32)  // skip length prefix
            eqKeccakHash := mload(ptr)        // first bytes32
            eqDataRoot := mload(add(ptr, 32)) // second bytes32
        }

        // First verify the equivalency proof (im assuming this call reverts if the proof ins invalid, so we move onward from here)
        ISP1Verifier(SP1_GROTH_16_VERIFIER).verifyProof(eqsVkey, input.publicValues, input.equivalenceProof);

        // lastly we verify the data root is inside of blobstream
        bool valid = IDAOracle(BLOBSTREAM).verifyAttestation(
            input.attestationProof.tupleRootNonce,
            input.attestationProof.tuple,
            input.attestationProof.proof
        );

        // can use custom error or whatever matter labs likes the most
        if (!valid) revert InvalidProof();

        output.stateDiffHash = l2DAValidatorOutputHash;

        if (output.stateDiffHash != eqKeccakHash)
            revert OperatorDAHashMismatch(eqKeccakHash, output.stateDiffHash);
        if (input.attestationProof.tuple.dataRoot != eqDataRoot)
            revert DataRootMismatch(eqDataRoot, input.attestationProof.tuple.dataRoot);

        output.blobsLinearHashes = new bytes32[](_maxBlobsSupported);
        output.blobsOpeningCommitments = new bytes32[](_maxBlobsSupported);
    }
}
