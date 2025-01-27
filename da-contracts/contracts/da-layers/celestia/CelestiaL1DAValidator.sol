pragma solidity 0.8.24;

import {IL1DAValidator, L1DAValidatorOutput} from "../../IL1DAValidator.sol";
import {ISP1Verifier} from "../../../../lib/sp1-contracts/contracts/src/ISP1Verifier.sol";

struct KeccakInclusionToDataRootOutput {
    bytes32 keccakHash;
    bytes32 dataRoot;
}

contract CelestiaL1DAValidator is IL1DAValidator {

    ISP1Verifier public sp1Verifier;

    constructor(ISP1Verifier _sp1Verifier) {
        sp1Verifier = _sp1Verifier;
    }

    function checkDA(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes32 _l2DAValidatorOutputHash,
        bytes calldata _operatorDAInput,
        uint256 _maxBlobsSupported
    ) external returns (L1DAValidatorOutput memory output) {

    }
}