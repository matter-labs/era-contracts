// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {StoredInteropRoot} from "contracts/common/Messaging.sol";

/// @notice `L1MessageRoot.recordL1BlockHash`, the record anchors are checked against. The Bridgehub is mocked to
/// isolate the message root. See {protocol-docs/l1sload.md#anchors}.
contract L1MessageRootL1SloadTest is Test {
    L1MessageRoot internal messageRoot;

    function setUp() public {
        address bridgehub = makeAddr("bridgehub");
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(new uint256[](0))
        );
        messageRoot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(bridgehub, makeAddr("chainAssetHandler"))),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(L1MessageRoot.initialize, ())
                )
            )
        );
    }

    /// @dev Permissionless; the record outlives the EVM's 256-block `blockhash` window.
    function test_recordL1BlockHash() public {
        bytes32 blockHash = keccak256("l1-block-1000");
        vm.roll(1001);
        vm.setBlockhash(1000, blockHash);

        vm.expectEmit(address(messageRoot));
        emit IL1MessageRoot.L1BlockHashRecorded(1000, blockHash, block.timestamp);
        vm.prank(makeAddr("anyone"));
        (uint256 recordedNumber, bytes32 recordedHash) = messageRoot.recordL1BlockHash();

        assertEq(recordedNumber, 1000);
        assertEq(recordedHash, blockHash);
        vm.roll(10_000);
        StoredInteropRoot memory recorded = messageRoot.recordedL1BlockHash(1000);
        assertEq(recorded.root, blockHash);
        assertEq(recorded.timestamp, 1);
        assertEq(messageRoot.recordedL1BlockHash(1001).root, bytes32(0));
    }

    /// @dev Every chain committing in one L1 block records the same block: only the first call writes and emits.
    function test_recordL1BlockHash_idempotentWithinABlock() public {
        vm.roll(51);
        vm.setBlockhash(50, keccak256("l1-block-50"));
        messageRoot.recordL1BlockHash();

        vm.warp(block.timestamp + 1);
        vm.recordLogs();
        messageRoot.recordL1BlockHash();

        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(messageRoot.recordedL1BlockHash(50).timestamp, 1, "the first record stays");
    }
}
