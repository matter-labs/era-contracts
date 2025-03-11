pragma solidity 0.8.24;

import {IL1DAValidator, L1DAValidatorOutput} from "../../IL1DAValidator.sol";

struct CelestiaZKStackInput {
    AttestationProof attestationProof;
    bytes equivalenceProof;
}

struct DataRootTuple {
    // Celestia block height the data root was included in.
    // Genesis block is height = 0.
    // First queryable block is height = 1.
    uint256 height;
    // Data root.
    bytes32 dataRoot;
}

/// @notice Merkle Tree Proof structure.
struct BinaryMerkleProof {
    // List of side nodes to verify and calculate tree.
    bytes32[] sideNodes;
    // The key of the leaf to verify.
    uint256 key;
    // The number of leaves in the tree
    uint256 numLeaves;
}

/// @notice Contains the necessary parameters needed to verify that a data root tuple
/// was committed to, by the Blobstream smart contract, at some specif nonce.
struct AttestationProof {
    // the attestation nonce that commits to the data root tuple.
    uint256 tupleRootNonce;
    // the data root tuple that was committed to.
    DataRootTuple tuple;
    // the binary merkle proof of the tuple to the commitment.
    BinaryMerkleProof proof;
}

interface IDAOracle {
    /// @notice Verify a Data Availability attestation.
    /// @param _tupleRootNonce Nonce of the tuple root to prove against.
    /// @param _tuple Data root tuple to prove inclusion of.
    /// @param _proof Binary Merkle tree proof that `tuple` is in the root at `_tupleRootNonce`.
    /// @return `true` is proof is valid, `false` otherwise.
    function verifyAttestation(
        uint256 _tupleRootNonce,
        DataRootTuple memory _tuple,
        BinaryMerkleProof memory _proof
    ) external view returns (bool);
}

interface ISP1Verifier {
    /// @notice Verifies a proof with given public values and vkey.
    /// @dev It is expected that the first 4 bytes of proofBytes must match the first 4 bytes of
    /// target verifier's VERIFIER_HASH.
    /// @param programVKey The verification key for the RISC-V program.
    /// @param publicValues The public values encoded as bytes.
    /// @param proofBytes The proof of the program execution the SP1 zkVM encoded as bytes.
    function verifyProof(bytes32 programVKey, bytes calldata publicValues, bytes calldata proofBytes) external view;
}

contract CelestiaL1DAValidator is IL1DAValidator {
    address public constant SP1_GROTH_16_VERIFIER = 0x397A5f7f3dBd538f23DE225B51f532c34448dA9B;

    // THIS is the SEPOLIA address, make sure each deployment has the right address!
    address public constant BLOBSTREAM = 0xF0c6429ebAB2e7DC6e05DaFB61128bE21f13cb1e;

    function checkDA(
        uint256,
        uint256,
        bytes32,
        bytes calldata _operatorDAInput,
        uint256 _maxBlobsSupported
    ) external returns (L1DAValidatorOutput memory output) {
        CelestiaZKStackInput memory input = abi.decode(_operatorDAInput, (CelestiaZKStackInput));

        (bytes32 programVKey, bytes memory publicValues, bytes memory proofBytes) = abi.decode(
            input.equivalenceProof,
            (bytes32, bytes, bytes)
        );

        // First verify the equivalency proof (im assuming this call reverts if the proof ins invalid, so we move onward from here)
        ISP1Verifier(SP1_GROTH_16_VERIFIER).verifyProof(programVKey, publicValues, proofBytes);

        // lastly we verify the data root is inside of blobstream
        bool valid = IDAOracle(BLOBSTREAM).verifyAttestation(
            input.attestationProof.tupleRootNonce,
            input.attestationProof.tuple,
            input.attestationProof.proof
        );

        // can use custom error or whatever matter labs likes the most
        if (!valid) revert("INVALID_PROOF");

        // does our input include the DA hash or do we get it from somewhere else and how do we properly fill these out
        output.stateDiffHash = bytes32(_operatorDAInput[:32]);

        // Do we need this?
        output.blobsLinearHashes = new bytes32[](_maxBlobsSupported);
        output.blobsOpeningCommitments = new bytes32[](_maxBlobsSupported);
    }
}
