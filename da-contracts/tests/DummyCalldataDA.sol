// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {CalldataDA} from "../contracts/CalldataDA.sol";

contract DummyCalldataDA is CalldataDA {
    function processL2RollupDAValidatorOutputHash(
        bytes32 _l2DAValidatorOutputHash,
        uint256 _maxBlobsSupported,
        bytes calldata _operatorDAInput
    )
        external
        pure
        returns (
            bytes32 stateDiffHash,
            bytes32 fullPubdataHash,
            bytes32[] memory blobsLinearHashes,
            uint256 blobsProvided,
            bytes calldata l1DaInput
        )
    {
        return _processL2RollupDAValidatorOutputHash(_l2DAValidatorOutputHash, _maxBlobsSupported, _operatorDAInput);
    }

    function processCalldataDA(
        uint256 _blobsProvided,
        bytes32 _fullPubdataHash,
        uint256 _maxBlobsSupported,
        bytes calldata _pubdataInput
    ) external pure virtual returns (bytes32[] memory blobCommitments, bytes calldata _pubdata) {
        return _processCalldataDA(_blobsProvided, _fullPubdataHash, _maxBlobsSupported, _pubdataInput);
    }

    function cloneCalldata(bytes32[] memory _dst, bytes calldata _input, uint256 _len) external pure {
        _cloneCalldata(_dst, _input, _len);
    }
}
