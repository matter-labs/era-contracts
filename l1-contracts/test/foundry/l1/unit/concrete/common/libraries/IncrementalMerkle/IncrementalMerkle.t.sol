// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IncrementalMerkleTest} from "contracts/dev-contracts/test/IncrementalMerkleTest.sol";
import {DynamicIncrementalMerkle} from "contracts/common/libraries/DynamicIncrementalMerkle.sol";
import {console} from "forge-std/console.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH} from "contracts/common/l2-helpers/IL2Messenger.sol";

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
        merkleTestMemory = DynamicIncrementalMerkle.Bytes32PushTree(0, new bytes32[](100), new bytes32[](100), 0, 0);
        merkleTestMemory.setupMemory(zero);
    }

    function testCheckSetup() public {
        DynamicIncrementalMerkle.Bytes32PushTree memory merkleTestMemory = setUpMemory();

        assertEq(merkleTest.height(), 0);
        assertEq(merkleTest.index(), 0);

        assertEq(merkleTestMemory.heightMemory(), 0);
        assertEq(merkleTestMemory._nextLeafIndex, 0);
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
        DynamicIncrementalMerkle.Bytes32PushTree memory merkleTestMemory = setUpMemory();
        // [0x54455d451af06b0282cfdea6a5a2be64accc7f74b3cdeebc45e16dd5fe7f1228, 0x3410756c0edc53d1d17d87a13e5a99d51be37981ef9d081f8edbed39aa45897e, 0x5efbf9df485ac6b910823e713bc4094077a4c490dd1218b58e057eeffa498620, 0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21]        // merkleTestMemory.pushMemory(bytes32(uint256(2)));
        merkleTestMemory.pushMemory(bytes32(hex"54455d451af06b0282cfdea6a5a2be64accc7f74b3cdeebc45e16dd5fe7f1228"));
        console.logBytes32(merkleTestMemory._sides[0]);
        console.logBytes32(merkleTestMemory._sides[1]);
        console.logBytes32(merkleTestMemory._sides[2]);
        console.logBytes32(merkleTestMemory._sides[3]);

        merkleTestMemory.pushMemory(bytes32(hex"3410756c0edc53d1d17d87a13e5a99d51be37981ef9d081f8edbed39aa45897e"));
        console.log("sides");
        console.logBytes32(merkleTestMemory._sides[0]);
        console.logBytes32(merkleTestMemory._sides[1]);
        console.logBytes32(merkleTestMemory._sides[2]);
        console.logBytes32(merkleTestMemory._sides[3]);
        merkleTestMemory.pushMemory(bytes32(hex"5efbf9df485ac6b910823e713bc4094077a4c490dd1218b58e057eeffa498620"));
        console.log("sides");
        console.logBytes32(merkleTestMemory._sides[0]);
        console.logBytes32(merkleTestMemory._sides[1]);
        console.logBytes32(merkleTestMemory._sides[2]);
        console.logBytes32(merkleTestMemory._sides[3]);
        merkleTestMemory.pushMemory(bytes32(hex"46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21"));
        console.log("sides");
        console.logBytes32(merkleTestMemory._sides[0]);
        console.logBytes32(merkleTestMemory._sides[1]);
        console.logBytes32(merkleTestMemory._sides[2]);
        console.logBytes32(merkleTestMemory._sides[3]);
        // merkleTestMemory.pushMemory(bytes32(hex"b1eb8605c1e1fb17809421a68d9ad15afed2207c7f12670a4dcfd6ee8260d2de"));
        // console.log("sides");
        // console.logBytes32(merkleTestMemory._sides[0]);
        // console.logBytes32(merkleTestMemory._sides[1]);
        // console.logBytes32(merkleTestMemory._sides[2]);
        // console.logBytes32(merkleTestMemory._sides[3]);
        // merkleTestMemory.pushMemory(bytes32(hex"72167a4002ac98b9768b5b127c3ef64ad44500e9a8b2fa6875a870c389461662"));
        // console.log("sides");
        // console.logBytes32(merkleTestMemory._sides[0]);
        // console.logBytes32(merkleTestMemory._sides[1]);
        // console.logBytes32(merkleTestMemory._sides[2]);
        // console.logBytes32(merkleTestMemory._sides[3]);
        // merkleTestMemory.pushMemory(bytes32(hex"5831859a651314f9898b77e8d336aeab3a6134c6138bb9227163594687ed7192"));
        // console.log("sides");
        // console.logBytes32(merkleTestMemory._sides[0]);
        // console.logBytes32(merkleTestMemory._sides[1]);
        // console.logBytes32(merkleTestMemory._sides[2]);
        // console.logBytes32(merkleTestMemory._sides[3]);
        // merkleTestMemory.pushMemory(bytes32(hex"7c5e3bcaaaa32ddc3954d3836cad66c26e674d59a5e8fa2b3a91421510ea2ecc"));
        // console.log("sides");
        // console.logBytes32(merkleTestMemory._sides[0]);
        // console.logBytes32(merkleTestMemory._sides[1]);
        // console.logBytes32(merkleTestMemory._sides[2]);
        // console.logBytes32(merkleTestMemory._sides[3]);
        console.log("zeros");
        console.logBytes32(merkleTestMemory._zeros[0]);
        console.logBytes32(merkleTestMemory._zeros[1]);
        console.logBytes32(merkleTestMemory._zeros[2]);
        console.logBytes32(merkleTestMemory._zeros[3]);
        console.logBytes32(merkleTestMemory._zeros[4]);

        console.log("roots");
        bytes32 aggregatedRootHash = hex"e4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf75944";
        console.logBytes32(merkleTestMemory.rootMemory());
        console.logBytes32(keccak256(bytes.concat(L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, aggregatedRootHash)));
        console.logBytes32(keccak256(bytes.concat(merkleTestMemory.rootMemory(), aggregatedRootHash)));

        merkleTestMemory.rootMemory();
    }
}
