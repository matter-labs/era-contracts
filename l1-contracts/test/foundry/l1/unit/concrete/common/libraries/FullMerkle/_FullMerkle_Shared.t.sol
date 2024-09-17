// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {FullMerkleTest as FullMerkleTestContract} from "contracts/dev-contracts/test/FullMerkleTest.sol";

contract FullMerkleTest is Test {
    // add this to be excluded from coverage report
    function test() internal {}

    FullMerkleTestContract internal merkleTest;
    bytes32 constant zeroHash = keccak256(abi.encodePacked("ZERO"));

    function setUp() public {
        merkleTest = new FullMerkleTestContract(zeroHash);
    }

    // ### Helper functions ###
    function keccak(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }
}
