// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IncrementalMerkleTest} from "contracts/dev-contracts/test/IncrementalMerkleTest.sol";

contract IncrementalMerkleTestTest is Test {
    IncrementalMerkleTest merkleTest;
    bytes32[] elements;
    bytes32 root;
    bytes32 zero = "0x1234567";

    function setUp() public {
        merkleTest = new IncrementalMerkleTest(zero);
    }

    function testCheckSetup() public {
        assertEq(merkleTest.height(), 0);
        assertEq(merkleTest.index(), 0);
    }

    function testSingleElement() public {
        addMoreElements(1);

        assertEq(merkleTest.root(), bytes32(abi.encodePacked(uint256(0))));
        assertEq(merkleTest.height(), 0);
        assertEq(merkleTest.index(), 1);
    }

    function testTwoElements() public {
        addMoreElements(2);

        assertEq(merkleTest.root(), keccak256(abi.encodePacked(uint256(0), uint256(1))));
        assertEq(merkleTest.index(), 2);
        assertEq(merkleTest.height(), 1);
    }

    function testPrepare3Elements() public {
        merkleTest.push(bytes32(uint256(2)));
        merkleTest.push(bytes32(uint256(zero)));
        assertEq(merkleTest.index(), 2);
        assertEq(merkleTest.height(), 1);
        assertEq(merkleTest.zeros(0), zero);

        assertEq(merkleTest.root(), keccak256(abi.encodePacked(uint256(2), uint256(zero))));
    }

    function testThreeElements() public {
        addMoreElements(3);

        assertEq(merkleTest.index(), 3);
        assertEq(merkleTest.height(), 2);
        assertEq(merkleTest.zeros(0), zero);
        assertEq(merkleTest.zeros(1), keccak256(abi.encodePacked(uint256(zero), uint256(zero))));
        assertEq(merkleTest.zeros(2), keccak256(abi.encodePacked(merkleTest.zeros(1), merkleTest.zeros(1))));
        assertEq(merkleTest.side(0), bytes32((uint256(2))));
        assertEq(merkleTest.side(1), keccak256(abi.encodePacked(uint256(0), uint256(1))));
        assertEq(
            merkleTest.root(),
            keccak256(
                abi.encodePacked(
                    keccak256(abi.encodePacked(uint256(0), uint256(1))),
                    keccak256(abi.encodePacked(uint256(2), uint256(zero)))
                )
            )
        );
    }

    function addMoreElements(uint256 n) public {
        for (uint256 i = 0; i < n; i++) {
            elements.push(bytes32(abi.encodePacked(i)));
            merkleTest.push(elements[i]);
        }
    }
}
