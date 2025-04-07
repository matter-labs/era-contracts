// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IncrementalMerkleTest} from "contracts/dev-contracts/test/IncrementalMerkleTest.sol";
import {DynamicIncrementalMerkle} from "contracts/common/libraries/DynamicIncrementalMerkle.sol";
import {console} from "forge-std/console.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH} from "contracts/common/l2-helpers/IL2ToL1Messenger.sol";

contract IncrementalMerkleTestTest is Test {
    using DynamicIncrementalMerkle for DynamicIncrementalMerkle.Bytes32PushTree;

    IncrementalMerkleTest merkleTest;
    bytes32[] elements;
    bytes32 root;
    bytes32 zero = hex"72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba";

    function setUp() public {
        merkleTest = new IncrementalMerkleTest(zero);
    }

    function setUpMemory() public returns (DynamicIncrementalMerkle.Bytes32PushTree memory merkleTestMemory) {
        // merkleTestMemory = DynamicIncrementalMerkle;
        merkleTestMemory = DynamicIncrementalMerkle.Bytes32PushTree(0, new bytes32[](14), new bytes32[](14), 0, 0);
        merkleTestMemory.setupMemory(zero);
    }

    function testCheckSetup() public {
        DynamicIncrementalMerkle.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        assertEq(merkleTest.height(), 0);
        assertEq(merkleTest.index(), 0);

        assertEq(merkleTestMemory.heightMemory(), 0);
        assertEq(merkleTestMemory._nextLeafIndex, 0);
    }

    function testExtend() public {
        DynamicIncrementalMerkle.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        merkleTest.extendUntilEnd(14);
        merkleTestMemory.extendUntilEndMemory();

        assertEq(merkleTest.sidesLength(), 14);
    }

    function testSingleElement() public {
        DynamicIncrementalMerkle.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        addMoreElements(1, merkleTestMemory);

        assertEq(merkleTest.root(), bytes32(abi.encodePacked(uint256(0))));
        assertEq(merkleTest.height(), 0);
        assertEq(merkleTest.index(), 1);

        assertEq(merkleTestMemory.rootMemory(), bytes32(abi.encodePacked(uint256(0))));
        assertEq(merkleTestMemory.heightMemory(), 0);
        assertEq(merkleTestMemory._nextLeafIndex, 1);
    }

    function testTwoElements() public {
        DynamicIncrementalMerkle.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        addMoreElements(2, merkleTestMemory);

        assertEq(merkleTest.root(), keccak256(abi.encodePacked(uint256(0), uint256(1))));
        assertEq(merkleTest.index(), 2);
        assertEq(merkleTest.height(), 1);

        assertEq(merkleTestMemory.rootMemory(), keccak256(abi.encodePacked(uint256(0), uint256(1))));
        assertEq(merkleTestMemory._nextLeafIndex, 2);
        assertEq(merkleTestMemory.heightMemory(), 1);
    }

    function testPrepare3Elements() public {
        DynamicIncrementalMerkle.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        merkleTest.push(bytes32(uint256(2)));
        merkleTest.push(bytes32(uint256(zero)));
        assertEq(merkleTest.index(), 2);
        assertEq(merkleTest.height(), 1);
        assertEq(merkleTest.zeros(0), zero);

        assertEq(merkleTest.root(), keccak256(abi.encodePacked(uint256(2), uint256(zero))));

        merkleTestMemory.pushMemory(bytes32(uint256(2)));
        merkleTestMemory.pushMemory(bytes32(uint256(zero)));
        assertEq(merkleTestMemory._nextLeafIndex, 2);
        assertEq(merkleTestMemory.heightMemory(), 1);
        assertEq(merkleTestMemory._zeros[0], zero);

        assertEq(merkleTestMemory.rootMemory(), keccak256(abi.encodePacked(uint256(2), uint256(zero))));
    }

    function testThreeElements() public {
        DynamicIncrementalMerkle.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        addMoreElements(3, merkleTestMemory);

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

        assertEq(merkleTestMemory._nextLeafIndex, 3);
        assertEq(merkleTestMemory.heightMemory(), 2);
        assertEq(merkleTestMemory._zeros[0], zero);
        assertEq(merkleTestMemory._zeros[1], keccak256(abi.encodePacked(uint256(zero), uint256(zero))));
        assertEq(
            merkleTestMemory._zeros[2],
            keccak256(abi.encodePacked(merkleTestMemory._zeros[1], merkleTestMemory._zeros[1]))
        );
        assertEq(merkleTestMemory._sides[0], bytes32((uint256(2))));
        assertEq(merkleTestMemory._sides[1], keccak256(abi.encodePacked(uint256(0), uint256(1))));
        assertEq(
            merkleTestMemory.rootMemory(),
            keccak256(
                abi.encodePacked(
                    keccak256(abi.encodePacked(uint256(0), uint256(1))),
                    keccak256(abi.encodePacked(uint256(2), uint256(zero)))
                )
            )
        );
    }

    function addMoreElements(uint256 n, DynamicIncrementalMerkle.Bytes32PushTree memory merkleTestMemory) public {
        for (uint256 i = 0; i < n; i++) {
            elements.push(bytes32(abi.encodePacked(i)));
            merkleTest.push(elements[i]);
            merkleTestMemory.pushMemory(elements[i]);
        }
    }

    function testFromServer() public {
        uint256 length = 15;
        DynamicIncrementalMerkle.Bytes32PushTree memory merkleTestMemory = DynamicIncrementalMerkle.Bytes32PushTree(
            0,
            new bytes32[](length),
            new bytes32[](length),
            0,
            0
        );
        merkleTestMemory.setupMemory(zero);
        merkleTestMemory.pushMemory(bytes32(hex"63c4d39ce8f2410a1e65b0ad1209fe8b368928a7124bfa6e10e0d4f0786129dd"));
        merkleTestMemory.pushMemory(bytes32(hex"bcc3a5584fe0f85e968c0bae082172061e3f3a8a47ff9915adae4a3e6174fc12"));
        merkleTestMemory.pushMemory(bytes32(hex"8d1ced168691d5e8a2dc778350a2c40a2714cc7d64bff5b8da40a96c47dc5f3e"));

        merkleTestMemory.extendUntilEndMemory();
        // bytes32 aggregatedRootHash = hex"e4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf75944";

        console.logBytes32(merkleTestMemory.rootMemory());
        // console.logBytes32(keccak256(bytes.concat(L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, aggregatedRootHash)));
        // console.logBytes32(keccak256(bytes.concat(merkleTestMemory.rootMemory(), aggregatedRootHash)));

        merkleTestMemory.rootMemory();
    }
}
