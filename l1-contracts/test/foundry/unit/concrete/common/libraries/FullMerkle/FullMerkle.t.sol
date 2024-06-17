// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";

import {FullMerkleTest} from "contracts/dev-contracts/test/FullMerkleTest.sol";

contract FullMerkleTestTest is Test {
    FullMerkleTest private merkleTest;
    bytes32 constant zeroHash = keccak256(abi.encodePacked("ZERO"));

    function setUp() public {
        merkleTest = new FullMerkleTest(zeroHash);
    }

    function testCheckSetup() public {
        assertEq(merkleTest.height(), 0, "Height should be correctly set to 3");
        assertEq(merkleTest.zeros(0), zeroHash, "Zero hash should be correctly initialized");
    }

    function testPushOneNewLeaf() public {
        merkleTest.pushNewLeaf(bytes32(0));
        assertEq(merkleTest.height(), 0, "Height should be 0 after three inserts");
        assertEq(merkleTest.index(), 1, "Leaf number should be 1 after one insert");
        assertEq(merkleTest.node(0, 0), bytes32(0), "Node 1,0 should be correctly inserted");
    }

    function testPushTwoLeaves() public {
        // Set up initial state with two leaves
        merkleTest.pushNewLeaf(bytes32(0));
        merkleTest.pushNewLeaf(bytes32(uint256(1)));
        assertEq(merkleTest.height(), 1, "Height should be 1 after three inserts");
        assertEq(merkleTest.index(), 2, "Leaf number should be 2 after two inserts");
        assertEq(merkleTest.node(0, 0), bytes32(0), "Node 0,0 should be correctly inserted");
        assertEq(merkleTest.node(0, 1), bytes32(uint256(1)), "Node 0,1 should be correctly inserted");
        bytes32 node = keccak(bytes32(0), bytes32(uint256(1)));
        bytes32 zeroHashed = keccak(zeroHash, zeroHash);
        assertEq(merkleTest.node(1, 0), node, "Node 1,0 should be correctly inserted");
        assertEq(merkleTest.zeros(1), zeroHashed, "Zero 1 should be correctly inserted");
    }

    function testPushThreeLeaves() public {
        // Set up initial state with two leaves
        merkleTest.pushNewLeaf(bytes32(0));
        merkleTest.pushNewLeaf(bytes32(uint256(1)));
        merkleTest.pushNewLeaf(bytes32(uint256(2)));
        assertEq(merkleTest.height(), 2, "Height should be 2 after three inserts");
        assertEq(merkleTest.index(), 3, "Leaf number should be 2 after two inserts");
        assertEq(merkleTest.node(0, 0), bytes32(0), "Node 0,0 should be correctly inserted");
        assertEq(merkleTest.node(0, 1), bytes32(uint256(1)), "Node 0,1 should be correctly inserted");
        assertEq(merkleTest.node(0, 2), bytes32(uint256(2)), "Node 0,2 should be correctly inserted");
        bytes32 node = keccak(bytes32(0), bytes32(uint256(1)));
        bytes32 node2 = keccak(bytes32(uint256(2)), merkleTest.zeros(0));
        assertEq(merkleTest.node(1, 0), node, "Node 1,0 should be correctly inserted");
        assertEq(merkleTest.node(1, 1), node2, "Node 1,1 should be correctly inserted");
        node = keccak(node, node2);
        bytes32 zeroHashed = keccak(merkleTest.zeros(1), merkleTest.zeros(1));
        assertEq(merkleTest.zeros(2), zeroHashed, "Zero 2 should be correctly inserted");
        assertEq(merkleTest.node(2, 0), node, "Node 2,0 should be correctly inserted");
    }

    function testUpdateLeaf() public {
        // Update second leaf
        merkleTest.pushNewLeaf(bytes32(0));
        merkleTest.pushNewLeaf(bytes32(uint256(1)));
        merkleTest.updateLeaf(1, bytes32(uint256(2)));
        assertEq(merkleTest.node(0, 0), bytes32(0), "Node 0,0 should be correctly inserted");
        assertEq(merkleTest.node(0, 1), bytes32(uint256(2)), "Node 0,1 should be correctly inserted");
        bytes32 node = keccak(bytes32(0), bytes32(uint256(2)));
        assertEq(merkleTest.node(1, 0), node, "Node 1,0 should be correctly inserted");
    }

    // function testUpdateAllLeaves() public {
    //     // Setup initial leaves
    //     merkleTest.pushNewLeaf(keccak256("Leaf 1"));
    //     merkleTest.pushNewLeaf(keccak256("Leaf 2"));

    //     // Prepare new leaves for full update
    //     bytes32[] memory newLeaves = new bytes32[](2);
    //     newLeaves[0] = keccak256("New Leaf 1");
    //     newLeaves[1] = keccak256("New Leaf 2");

    //     // Update all leaves and verify root
    //     merkleTest.updateAllLeaves(newLeaves);

    //     // bytes32 expectedRoot = merkleTest._efficientHash(newLeaves[0], newLeaves[1]);
    //     // bytes32 actualRoot = merkleTest._nodes[tree._height - 1][0];
    //     // assertEq(actualRoot, expectedRoot, "Root should match expected hash after full update");
    // }

    function keccak(bytes32 left, bytes32 right) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }
}
