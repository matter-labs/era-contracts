// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {OnlyBridgehub, MessageRootNotRegistered} from "contracts/bridgehub/L1BridgehubErrors.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {L2MessageVerification} from "contracts/bridgehub/L2MessageVerification.sol";
import {L2Log} from "contracts/common/Messaging.sol";
// import {IL2MessageRootStorage} from "contracts/common/interfaces/IL2MessageRootStorage.sol";
import {L2_MESSAGE_ROOT_STORAGE} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

// Chain tree consists of batch commitments as their leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant CHAIN_TREE_EMPTY_ENTRY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

// Chain tree consists of batch commitments as their leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant SHARED_ROOT_TREE_EMPTY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

contract MessageRootTest is Test {
    address bridgeHub;
    L2MessageVerification l2MessageVerification;

    function setUp() public {
        bridgeHub = makeAddr("bridgeHub");
        l2MessageVerification = new L2MessageVerification();
    }

    function test_l2MessageVerification() public {
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
        bytes32[] memory proof = new bytes32[](4);
        proof[0] = bytes32(0x0103000100000000000000000000000000000000000000000000000000000000);
        proof[1] = bytes32(0x32b59b40b87cf8e6ed0cbe1b5ff159ae24e29e9b924068f10a8719ebd5d9f6de);
        proof[2] = bytes32(0x74ba85451a61e8c7007a0f940e1ae069b3769932fca68148f2842d5c7edd253e);
        proof[3] = bytes32(0xe4ed1ec13a28c40715db6399f6f99ce04e5f19d60ad3ff6831f098cb6cf75944);
        vm.mockCall(
            address(L2_MESSAGE_ROOT_STORAGE),
            abi.encodeWithSelector(L2_MESSAGE_ROOT_STORAGE.msgRoots.selector),
            abi.encode(bytes32(0x46ab0a3240394cd4339c065011ad354c67d269d3c6e0f8ad7eb2eb4b8a3ffb49))
        );
        bool isIncluded = l2MessageVerification.proveL2LogInclusionShared(
            chainId,
            batchNumber,
            l2ToL1LogIndex,
            log,
            proof
        );
        assertEq(isIncluded, true);
    }

    function test_l2MessageVerification_with_double_proof() public {
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
        /// get this value from a real withdrawal by running integration tests.
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
            address(L2_MESSAGE_ROOT_STORAGE),
            abi.encodeWithSelector(L2_MESSAGE_ROOT_STORAGE.msgRoots.selector),
            abi.encode(bytes32(0x9df9ccdcc86232686d57ea501eadb14888fd7c9fe1fd72a74c91208f11e864d5))
        );
        bool isIncluded = l2MessageVerification.proveL2LogInclusionShared(
            chainId,
            batchNumber,
            l2ToL1LogIndex,
            log,
            proof
        );
        assertEq(isIncluded, true);
    }
}
