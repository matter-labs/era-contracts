pragma solidity 0.8.24;

import {IL1DAValidator, L1DAValidatorOutput} from "../../IL1DAValidator.sol";

contract CelestiaL1DAValidator is IL1DAValidator {

    function checkDA(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes32 _l2DAValidatorOutputHash,
        bytes calldata _operatorDAInput,
        uint256 _maxBlobsSupported
    ) external returns (L1DAValidatorOutput memory output) {

    }
}