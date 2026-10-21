// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {StoredInteropRoot} from "contracts/common/Messaging.sol";

/// @notice The `L1MessageRoot` addition for L1SLOAD: the permanent L1 block-hash record that anchors are checked
/// against. The Bridgehub is mocked to isolate the message root. Suspension lives in `ChainRegistrationSender`, see
/// `ChainRegistrationSender.t.sol`. See {protocol-docs/l1sload.md#anchors}.
contract L1MessageRootL1SloadTest is Test {
    address internal bridgehub;
    L1MessageRoot internal messageRoot;

    function setUp() public {
        bridgehub = makeAddr("bridgehub");
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

    /*//////////////////////////////////////////////////////////////
                            recordL1BlockHash
    //////////////////////////////////////////////////////////////*/

    function test_recordL1BlockHash_recordsThePreviousBlock() public {
        uint256 blockNumber = 1000;
        bytes32 blockHash = keccak256("l1-block-1000");
        uint256 timestamp = 1_700_000_000;
        vm.roll(blockNumber + 1);
        vm.warp(timestamp);
        vm.setBlockhash(blockNumber, blockHash);

        vm.expectEmit(address(messageRoot));
        emit IL1MessageRoot.L1BlockHashRecorded(blockNumber, blockHash, timestamp);
        // Permissionless.
        vm.prank(makeAddr("anyone"));
        (uint256 recordedNumber, bytes32 recordedHash) = messageRoot.recordL1BlockHash();

        assertEq(recordedNumber, blockNumber);
        assertEq(recordedHash, blockHash);
        StoredInteropRoot memory recorded = messageRoot.recordedL1BlockHash(blockNumber);
        assertEq(recorded.root, blockHash);
        assertEq(recorded.timestamp, timestamp);
        assertEq(messageRoot.recordedL1BlockHash(blockNumber + 1).root, bytes32(0), "current block not recorded");
    }

    /// @dev The record outlives the EVM's 256-block `blockhash` window.
    function test_recordL1BlockHash_isPermanent() public {
        uint256 blockNumber = 1000;
        bytes32 blockHash = keccak256("l1-block-1000");
        vm.roll(blockNumber + 1);
        vm.setBlockhash(blockNumber, blockHash);
        messageRoot.recordL1BlockHash();

        vm.roll(blockNumber + 10_000);
        assertEq(blockhash(blockNumber), bytes32(0), "out of the EVM window");
        assertEq(messageRoot.recordedL1BlockHash(blockNumber).root, blockHash);
    }

    /// @dev Recording twice in one block writes the same values.
    function test_recordL1BlockHash_idempotentWithinABlock() public {
        vm.roll(51);
        vm.setBlockhash(50, keccak256("l1-block-50"));
        messageRoot.recordL1BlockHash();
        StoredInteropRoot memory first = messageRoot.recordedL1BlockHash(50);

        messageRoot.recordL1BlockHash();
        StoredInteropRoot memory second = messageRoot.recordedL1BlockHash(50);
        assertEq(second.root, first.root);
        assertEq(second.timestamp, first.timestamp);
    }

    function test_recordedL1BlockHash_zeroForUnrecordedBlocks() public view {
        StoredInteropRoot memory recorded = messageRoot.recordedL1BlockHash(12345);
        assertEq(recorded.root, bytes32(0));
        assertEq(recorded.timestamp, 0);
    }
}
