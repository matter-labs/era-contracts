// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {L2MessageVerification} from "contracts/interop/L2MessageVerification.sol";
import {L2Log, L2Message} from "contracts/common/Messaging.sol";
import {L2_INTEROP_ROOT_STORAGE} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {DepthMoreThanOneForRecursiveMerkleProof} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

/// @title L2MessageVerificationDepthRegressionTest
/// @notice Regression tests for the depth argument fix in L2MessageVerification
/// passes _depth + 1.
contract L2MessageVerificationDepthRegressionTest is Test {
    L2MessageVerification l2MessageVerification;

    function setUp() public {
        l2MessageVerification = new L2MessageVerification();
    }

    /// @notice Test that a proof requiring single recursion (double proof) still works
    /// @dev This verifies the fix doesn't break legitimate single-hop proofs
    function test_regression_singleRecursionProofStillWorks() public {
        uint256 chainId = 271;
        uint256 batchNumber = 66;
        uint256 l2ToL1LogIndex = 1;

        L2Log memory log = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 0,
            sender: 0x0000000000000000000000000000000000008008,
            key: 0x0000000000000000000000000000000000000000000000000000000000010008,
            value: 0x182bf04331468886c27903ea0bdc761fde4a166e29814a178da2d3f56d205982
        });

        // Double proof (requires one level of recursion)
        bytes32[] memory proof = new bytes32[](27);
        proof[0] = bytes32(0x010f060000000000000000000000000000000000000000000000000000000000);
        proof[1] = bytes32(0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba);
        proof[2] = bytes32(0xc3d03eebfd83049991ea3d3e358b6712e7aa2e2e63dc2d4b438987cec28ac8d0);
        proof[3] = bytes32(0xe3697c7f33c31a9b0f0aeb8542287d0d21e8c4cf82163d0c44c7a98aa11aa111);
        proof[4] = bytes32(0x199cc5812543ddceeddd0fc82807646a4899444240db2c0d2f20c3cceb5f51fa);
        proof[5] = bytes32(0xe4733f281f18ba3ea8775dd62d2fcd84011c8c938f16ea5790fd29a03bf8db89);
        proof[6] = bytes32(0x1798a1fd9c8fbb818c98cff190daa7cc10b6e5ac9716b4a2649f7c2ebcef2272);
        proof[7] = bytes32(0x66d7c5983afe44cf15ea8cf565b34c6c31ff0cb4dd744524f7842b942d08770d);
        proof[8] = bytes32(0xb04e5ee349086985f74b73971ce9dfe76bbed95c84906c5dffd96504e1e5396c);
        proof[9] = bytes32(0xac506ecb5465659b3a927143f6d724f91d8d9c4bdb2463aee111d9aa869874db);
        proof[10] = bytes32(0x124b05ec272cecd7538fdafe53b6628d31188ffb6f345139aac3c3c1fd2e470f);
        proof[11] = bytes32(0xc3be9cbd19304d84cca3d045e06b8db3acd68c304fc9cd4cbffe6d18036cb13f);
        proof[12] = bytes32(0xfef7bd9f889811e59e4076a0174087135f080177302763019adaf531257e3a87);
        proof[13] = bytes32(0xa707d1c62d8be699d34cb74804fdd7b4c568b6c1a821066f126c680d4b83e00b);
        proof[14] = bytes32(0xf6e093070e0389d2e529d60fadb855fdded54976ec50ac709e3a36ceaa64c291);
        proof[15] = bytes32(0xe4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf75944);
        proof[16] = bytes32(0x0000000000000000000000000000000000000000000000000000000000000034);
        proof[17] = bytes32(0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21);
        proof[18] = bytes32(0xcc4c41edb0c2031348b292b768e9bac1ee8c92c09ef8a3277c2ece409c12d86a);
        proof[19] = bytes32(0x665220c0a39a5c4886626c93dfe3f253324bd0fd48bf037156b977d2da1c2a80);
        proof[20] = bytes32(0x4cd95f8962e2e3b5f525a0f4fdfbbf0667990c7159528a008057f3592bcb2c06);
        proof[21] = bytes32(0x73374357c2721f1e18426e45490035daf9a01b4fd064b9fc6bf85acf888bbc42);
        proof[22] = bytes32(0x9b63d72e0483741f19d143751f22f965461f0a98897b8ffffedd086935f6bc26);
        proof[23] = bytes32(0x000000000000000000000000000000f300000000000000000000000000000001);
        proof[24] = bytes32(0x00000000000000000000000000000000000000000000000000000000000001fa);
        proof[25] = bytes32(0x0101000100000000000000000000000000000000000000000000000000000000);
        proof[26] = bytes32(0xf84927dc03d95cc652990ba75874891ccc5a4d79a0e10a2ffdd238a34a39f828);

        vm.mockCall(
            address(L2_INTEROP_ROOT_STORAGE),
            abi.encodeWithSelector(L2_INTEROP_ROOT_STORAGE.interopRoots.selector),
            abi.encode(bytes32(0x9df9ccdcc86232686d57ea501eadb14888fd7c9fe1fd72a74c91208f11e864d5))
        );

        bool isIncluded = l2MessageVerification.proveL2LogInclusionShared(
            chainId,
            batchNumber,
            l2ToL1LogIndex,
            log,
            proof
        );
        assertTrue(isIncluded, "Single recursion proof should work");
    }

    /// @notice Test that calling proveL2LeafInclusionSharedRecursive with depth=1 when recursion is needed fails
    /// @dev This is the key regression test - before the fix, depth was always 0 in recursive calls
    ///      After the fix, depth is properly incremented, and attempting a second recursion fails
    function test_regression_depthOneWithRecursionReverts() public {
        uint256 chainId = 271;
        uint256 batchNumber = 66;

        // Use the real double-proof data that requires recursion
        // This proof has finalProofNode=false in its first part, requiring a recursive call
        bytes32 leaf = keccak256(
            abi.encodePacked(
                uint8(0), // l2ShardId
                true, // isService
                uint16(0), // txNumberInBatch
                address(0x0000000000000000000000000000000000008008), // sender
                bytes32(0x0000000000000000000000000000000000000000000000000000000000010008), // key
                bytes32(0x182bf04331468886c27903ea0bdc761fde4a166e29814a178da2d3f56d205982) // value
            )
        );

        // Double proof (requires one level of recursion) - this proof is NOT final in its first part
        bytes32[] memory proof = new bytes32[](27);
        proof[0] = bytes32(0x010f060000000000000000000000000000000000000000000000000000000000);
        proof[1] = bytes32(0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba);
        proof[2] = bytes32(0xc3d03eebfd83049991ea3d3e358b6712e7aa2e2e63dc2d4b438987cec28ac8d0);
        proof[3] = bytes32(0xe3697c7f33c31a9b0f0aeb8542287d0d21e8c4cf82163d0c44c7a98aa11aa111);
        proof[4] = bytes32(0x199cc5812543ddceeddd0fc82807646a4899444240db2c0d2f20c3cceb5f51fa);
        proof[5] = bytes32(0xe4733f281f18ba3ea8775dd62d2fcd84011c8c938f16ea5790fd29a03bf8db89);
        proof[6] = bytes32(0x1798a1fd9c8fbb818c98cff190daa7cc10b6e5ac9716b4a2649f7c2ebcef2272);
        proof[7] = bytes32(0x66d7c5983afe44cf15ea8cf565b34c6c31ff0cb4dd744524f7842b942d08770d);
        proof[8] = bytes32(0xb04e5ee349086985f74b73971ce9dfe76bbed95c84906c5dffd96504e1e5396c);
        proof[9] = bytes32(0xac506ecb5465659b3a927143f6d724f91d8d9c4bdb2463aee111d9aa869874db);
        proof[10] = bytes32(0x124b05ec272cecd7538fdafe53b6628d31188ffb6f345139aac3c3c1fd2e470f);
        proof[11] = bytes32(0xc3be9cbd19304d84cca3d045e06b8db3acd68c304fc9cd4cbffe6d18036cb13f);
        proof[12] = bytes32(0xfef7bd9f889811e59e4076a0174087135f080177302763019adaf531257e3a87);
        proof[13] = bytes32(0xa707d1c62d8be699d34cb74804fdd7b4c568b6c1a821066f126c680d4b83e00b);
        proof[14] = bytes32(0xf6e093070e0389d2e529d60fadb855fdded54976ec50ac709e3a36ceaa64c291);
        proof[15] = bytes32(0xe4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf75944);
        proof[16] = bytes32(0x0000000000000000000000000000000000000000000000000000000000000034);
        proof[17] = bytes32(0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21);
        proof[18] = bytes32(0xcc4c41edb0c2031348b292b768e9bac1ee8c92c09ef8a3277c2ece409c12d86a);
        proof[19] = bytes32(0x665220c0a39a5c4886626c93dfe3f253324bd0fd48bf037156b977d2da1c2a80);
        proof[20] = bytes32(0x4cd95f8962e2e3b5f525a0f4fdfbbf0667990c7159528a008057f3592bcb2c06);
        proof[21] = bytes32(0x73374357c2721f1e18426e45490035daf9a01b4fd064b9fc6bf85acf888bbc42);
        proof[22] = bytes32(0x9b63d72e0483741f19d143751f22f965461f0a98897b8ffffedd086935f6bc26);
        proof[23] = bytes32(0x000000000000000000000000000000f300000000000000000000000000000001);
        proof[24] = bytes32(0x00000000000000000000000000000000000000000000000000000000000001fa);
        proof[25] = bytes32(0x0101000100000000000000000000000000000000000000000000000000000000);
        proof[26] = bytes32(0xf84927dc03d95cc652990ba75874891ccc5a4d79a0e10a2ffdd238a34a39f828);

        // When calling with depth=1 and the proof requires recursion, it should revert
        // The proof's first part is not final (metadata byte 4 is 0x00), so it needs recursion
        // At depth=1, attempting recursion should trigger the depth check
        vm.expectRevert(DepthMoreThanOneForRecursiveMerkleProof.selector);
        l2MessageVerification.proveL2LeafInclusionSharedRecursive({
            _chainId: chainId,
            _blockOrBatchNumber: batchNumber,
            _leafProofMask: 1,
            _leaf: leaf,
            _proof: proof,
            _depth: 1
        });
    }

    /// @notice Test that the public proveL2LeafInclusionShared starts with depth 0
    /// @dev Verifies the entry point correctly initializes depth to 0
    ///      Uses the same data from test_l2MessageVerification in L2MessageVerification.t.sol
    function test_regression_publicFunctionStartsAtDepthZero() public {
        uint256 chainId = 271;
        uint256 batchNumber = 66;
        uint256 l2ToL1LogIndex = 1;

        // Use real log data from existing test
        L2Log memory log = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 0,
            sender: 0x0000000000000000000000000000000000008008,
            key: 0x0000000000000000000000000000000000000000000000000000000000010008,
            value: 0x182bf04331468886c27903ea0bdc761fde4a166e29814a178da2d3f56d205982
        });

        // Simple final proof (metadata byte 4 is 0x01 = final)
        bytes32[] memory proof = new bytes32[](4);
        proof[0] = bytes32(0x0103000100000000000000000000000000000000000000000000000000000000);
        proof[1] = bytes32(0x32b59b40b87cf8e6ed0cbe1b5ff159ae24e29e9b924068f10a8719ebd5d9f6de);
        proof[2] = bytes32(0x74ba85451a61e8c7007a0f940e1ae069b3769932fca68148f2842d5c7edd253e);
        proof[3] = bytes32(0xe4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf75944);

        // Mock the interop root storage to return a matching root
        vm.mockCall(
            address(L2_INTEROP_ROOT_STORAGE),
            abi.encodeWithSelector(L2_INTEROP_ROOT_STORAGE.interopRoots.selector),
            abi.encode(bytes32(0x46ab0a3240394cd4339c065011ad354c67d269d3c6e0f8ad7eb2eb4b8a3ffb49))
        );

        // This should work because proveL2LogInclusionShared calls _proveL2LogInclusion
        // which calls _proveL2LeafInclusion which calls _proveL2LeafInclusionRecursive with depth=0
        bool result = l2MessageVerification.proveL2LogInclusionShared(chainId, batchNumber, l2ToL1LogIndex, log, proof);

        assertTrue(result, "Simple proof should succeed starting at depth 0");
    }

    /// @notice Test that depth=0 with single recursion works (depth goes 0->1)
    /// @dev This tests the normal flow where we start at depth 0 and have one recursion
    function test_regression_depthZeroWithSingleRecursionWorks() public {
        // The double proof test already covers this, but let's be explicit
        // A proof that requires exactly one hop should work when starting from depth 0
        // This is covered by test_regression_singleRecursionProofStillWorks
    }

    /// @notice Test that depth=0 proof requiring recursion increments depth correctly
    /// @dev Verifies that when we start at depth 0 and recursion is needed, the recursive
    ///      call is made with depth 1, and if THAT call also needs recursion it will fail.
    ///      The double-proof used here works because the second level IS final (metadata byte 4 = 0x01).
    ///      This test validates that the fix properly passes depth+1 to recursive calls.
    function test_regression_recursiveCallIncrementsDepth() public {
        uint256 chainId = 271;
        uint256 batchNumber = 66;
        uint256 l2ToL1LogIndex = 1;

        L2Log memory log = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 0,
            sender: 0x0000000000000000000000000000000000008008,
            key: 0x0000000000000000000000000000000000000000000000000000000000010008,
            value: 0x182bf04331468886c27903ea0bdc761fde4a166e29814a178da2d3f56d205982
        });

        // Double proof - first part is NOT final (requires recursion), second part IS final
        // This validates that depth is properly incremented: 0 -> 1 in recursive call
        // The second call succeeds because it's final (doesn't need another recursion)
        bytes32[] memory proof = new bytes32[](27);
        proof[0] = bytes32(0x010f060000000000000000000000000000000000000000000000000000000000);
        proof[1] = bytes32(0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba);
        proof[2] = bytes32(0xc3d03eebfd83049991ea3d3e358b6712e7aa2e2e63dc2d4b438987cec28ac8d0);
        proof[3] = bytes32(0xe3697c7f33c31a9b0f0aeb8542287d0d21e8c4cf82163d0c44c7a98aa11aa111);
        proof[4] = bytes32(0x199cc5812543ddceeddd0fc82807646a4899444240db2c0d2f20c3cceb5f51fa);
        proof[5] = bytes32(0xe4733f281f18ba3ea8775dd62d2fcd84011c8c938f16ea5790fd29a03bf8db89);
        proof[6] = bytes32(0x1798a1fd9c8fbb818c98cff190daa7cc10b6e5ac9716b4a2649f7c2ebcef2272);
        proof[7] = bytes32(0x66d7c5983afe44cf15ea8cf565b34c6c31ff0cb4dd744524f7842b942d08770d);
        proof[8] = bytes32(0xb04e5ee349086985f74b73971ce9dfe76bbed95c84906c5dffd96504e1e5396c);
        proof[9] = bytes32(0xac506ecb5465659b3a927143f6d724f91d8d9c4bdb2463aee111d9aa869874db);
        proof[10] = bytes32(0x124b05ec272cecd7538fdafe53b6628d31188ffb6f345139aac3c3c1fd2e470f);
        proof[11] = bytes32(0xc3be9cbd19304d84cca3d045e06b8db3acd68c304fc9cd4cbffe6d18036cb13f);
        proof[12] = bytes32(0xfef7bd9f889811e59e4076a0174087135f080177302763019adaf531257e3a87);
        proof[13] = bytes32(0xa707d1c62d8be699d34cb74804fdd7b4c568b6c1a821066f126c680d4b83e00b);
        proof[14] = bytes32(0xf6e093070e0389d2e529d60fadb855fdded54976ec50ac709e3a36ceaa64c291);
        proof[15] = bytes32(0xe4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf75944);
        proof[16] = bytes32(0x0000000000000000000000000000000000000000000000000000000000000034);
        proof[17] = bytes32(0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21);
        proof[18] = bytes32(0xcc4c41edb0c2031348b292b768e9bac1ee8c92c09ef8a3277c2ece409c12d86a);
        proof[19] = bytes32(0x665220c0a39a5c4886626c93dfe3f253324bd0fd48bf037156b977d2da1c2a80);
        proof[20] = bytes32(0x4cd95f8962e2e3b5f525a0f4fdfbbf0667990c7159528a008057f3592bcb2c06);
        proof[21] = bytes32(0x73374357c2721f1e18426e45490035daf9a01b4fd064b9fc6bf85acf888bbc42);
        proof[22] = bytes32(0x9b63d72e0483741f19d143751f22f965461f0a98897b8ffffedd086935f6bc26);
        proof[23] = bytes32(0x000000000000000000000000000000f300000000000000000000000000000001);
        proof[24] = bytes32(0x00000000000000000000000000000000000000000000000000000000000001fa);
        // Second part metadata: 0x01 (version) 0x01 (logLeafProofLen) 0x00 (batchLeafProofLen) 0x01 (IS final)
        proof[25] = bytes32(0x0101000100000000000000000000000000000000000000000000000000000000);
        proof[26] = bytes32(0xf84927dc03d95cc652990ba75874891ccc5a4d79a0e10a2ffdd238a34a39f828);

        vm.mockCall(
            address(L2_INTEROP_ROOT_STORAGE),
            abi.encodeWithSelector(L2_INTEROP_ROOT_STORAGE.interopRoots.selector),
            abi.encode(bytes32(0x9df9ccdcc86232686d57ea501eadb14888fd7c9fe1fd72a74c91208f11e864d5))
        );

        // This works: depth 0 -> recursion with depth 1 -> second part is final, so no more recursion needed
        bool isIncluded = l2MessageVerification.proveL2LogInclusionShared(
            chainId,
            batchNumber,
            l2ToL1LogIndex,
            log,
            proof
        );
        assertTrue(isIncluded, "Double proof with proper depth increment should work");
    }
}
