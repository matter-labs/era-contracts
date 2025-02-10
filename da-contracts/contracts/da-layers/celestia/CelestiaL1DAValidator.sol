pragma solidity 0.8.24;

import {IL1DAValidator, L1DAValidatorOutput} from "../../IL1DAValidator.sol";
import {ISP1Verifier} from "../../../../lib/sp1-contracts/contracts/src/ISP1Verifier.sol";
import {ISP1Blobstream} from "../../../../lib/sp1-blobstream/contracts/src/interfaces/ISP1Blobstream.sol";

struct KeccakInclusionToDataRootOutput {
    bytes32 keccakHash;
    bytes32 dataRoot;
}

contract CelestiaL1DAValidator is IL1DAValidator {

    ISP1Verifier public sp1Verifier;
    ISP1Blobstream public sp1Blobstream;

    constructor(ISP1Verifier _sp1Verifier, ISP1Blobstream _sp1Blobstream) {
        sp1Verifier = _sp1Verifier;
        sp1Blobstream = _sp1Blobstream;
    }

    function checkDA(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes32 _l2DAValidatorOutputHash,
        bytes calldata _operatorDAInput,
        uint256 _maxBlobsSupported
    ) external returns (L1DAValidatorOutput memory output) {

        KeccakInclusionToDataRootOutput memory keccakInclusionToDataRootOutput = abi.decode(_operatorDAInput, (KeccakInclusionToDataRootOutput));

        bytes32[] memory dataCommitments = sp1Blobstream.state_dataCommitments();

    }
}
