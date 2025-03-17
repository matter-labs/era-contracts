// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

contract DummyEigenDARegistry {
    mapping (uint256 => bytes32) public hashes;
    function isVerified(uint256 batchNumber) external view returns (bool, bytes32) {
        return (true, hashes[batchNumber]);
    }

    function verify(uint256 batchNumber, bytes32 eigenDAHash) external {
        hashes[batchNumber] = eigenDAHash;
    }
}
