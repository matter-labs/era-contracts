// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

interface IVerifier {
    function verify(
        uint256[] calldata _publicInputs,
        uint256[] calldata _proof,
        uint256[] calldata _recursiveAggregationInput
    ) external view returns (bool);

    function verificationKeyHash() external pure returns (bytes32);
}
