// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {CalldataDA, BLOB_COMMITMENT_SIZE, BLOB_SIZE_BYTES} from "./CalldataDA.sol";

// solhint-disable gas-custom-errors, reason-string

/// @notice Contract that contains the functionality for process the calldata DA.
/// @dev The expected l2DAValidator that should be used with it `RollupL2DAValidator`.
abstract contract CalldataDAGateway is CalldataDA {
    /// @inheritdoc CalldataDA
    function _processCalldataDA(
        uint256 _blobsProvided,
        bytes32 _fullPubdataHash,
        uint256 _maxBlobsSupported,
        bytes calldata _pubdataInput
    ) internal pure override returns (bytes32[] memory blobCommitments, bytes calldata _pubdata) {
        require(_pubdataInput.length >= _blobsProvided * BLOB_COMMITMENT_SIZE, "pubdata too small");

        // We typically do not know whether we'll use calldata or blobs at the time when
        // we start proving the batch. That's why the blob commitment for a single blob is still present in the case of calldata.
        blobCommitments = new bytes32[](_maxBlobsSupported);

        _pubdata = _pubdataInput[:_pubdataInput.length - _blobsProvided * BLOB_COMMITMENT_SIZE];

        require(_pubdata.length <= _blobsProvided * BLOB_SIZE_BYTES, "cz");
        require(_fullPubdataHash == keccak256(_pubdata), "wp");

        bytes calldata providedCommitments = _pubdataInput[_pubdataInput.length -
            _blobsProvided *
            BLOB_COMMITMENT_SIZE:];

        cloneCalldata(blobCommitments, providedCommitments, _blobsProvided);
    }
}
