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
}
