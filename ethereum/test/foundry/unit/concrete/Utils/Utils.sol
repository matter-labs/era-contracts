// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

library Utils {
    function packBatchTimestampAndBlockTimestamp(
        uint256 batchTimestamp,
        uint256 blockTimestamp
    ) public pure returns (bytes32) {
        uint256 packedNum = (batchTimestamp << 128) | blockTimestamp;
        return bytes32(packedNum);
    }

    function randomBytes32(bytes memory seed) public view returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, seed));
    }
}
