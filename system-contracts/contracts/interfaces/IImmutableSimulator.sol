// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

struct ImmutableData {
    uint256 index;
    bytes32 value;
}

interface IImmutableSimulator {
    function getImmutable(address _dest, uint256 _index) external view returns (bytes32);

    function setImmutables(address _dest, ImmutableData[] calldata _immutables) external;
}
