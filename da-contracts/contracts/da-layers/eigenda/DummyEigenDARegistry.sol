// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// This is the dummiest possible implementation, where the blobs are always assumed to be verified,
// and you only need to pass the hash of the blob
// In order to be production ready this contract lacks:
// - Verification of the inclusion data
// - Ownership checks
// - Upgradability
contract DummyEigenDARegistry {
    mapping(bytes => bytes32) public hashes;
    function isVerified(bytes calldata inclusion_data) external view returns (bool, bytes32) {
        return (true, hashes[inclusion_data]);
    }

    function verify(bytes calldata inclusion_data, bytes32 eigenDAHash) external {
        hashes[inclusion_data] = eigenDAHash;
    }
}
