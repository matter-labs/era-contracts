// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

contract DummyEigenDARegistry {
    mapping(bytes => bytes32) public hashes;
    function isVerified(bytes calldata inclusion_data) external view returns (bool, bytes32) {
        return (true, hashes[inclusion_data]);
    }

    function verify(bytes calldata inclusion_data, bytes32 eigenDAHash) external {
        hashes[inclusion_data] = eigenDAHash;
    }
}
