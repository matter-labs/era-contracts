// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BlobsL1DAValidatorZKsyncOS} from "../../contracts/BlobsL1DAValidatorZKsyncOS.sol";

/// @dev Mock contract to override _getBlobVersionedHash
contract MockBlobsL1DAValidator is BlobsL1DAValidatorZKsyncOS {
    bytes32[] internal mockBlobs;

    function setMockBlobs(bytes32[] calldata blobs) external {
        delete mockBlobs;
        uint256 len = blobs.length;
        for (uint256 i = 0; i < len; ++i) {
            mockBlobs.push(blobs[i]);
        }
    }

    function _getBlobVersionedHash(uint256 _index) internal view override returns (bytes32) {
        if (_index < mockBlobs.length) {
            return mockBlobs[_index];
        }
        return bytes32(0);
    }
}
