// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {StoredInteropRoot} from "contracts/common/Messaging.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {
    InteropAlreadyEnabled,
    InteropAlreadySuspended,
    InteropNotSuspended
} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

/// @notice The `L1MessageRoot` additions for L1SLOAD: the permanent L1 block-hash record and the reversible interop
/// suspension. The Bridgehub and the vault are mocked to isolate the message root. See {protocol-docs/l1sload.md}.
contract L1MessageRootL1SloadTest is Test {
    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant OTHER_CHAIN_ID = 272;

    address internal bridgehub;
    address internal governance;
    L1MessageRoot internal messageRoot;

    function setUp() public {
        bridgehub = makeAddr("bridgehub");
        governance = makeAddr("governance");
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
        vm.mockCall(bridgehub, abi.encodeCall(IOwnable.owner, ()), abi.encode(governance));

        // A registered chain that is ready for interop.
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.getZKChain, (CHAIN_ID)), abi.encode(makeAddr("chain")));
        address assetRouter = makeAddr("assetRouter");
        address nativeTokenVault = makeAddr("nativeTokenVault");
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.assetRouter, ()), abi.encode(assetRouter));
        vm.mockCall(assetRouter, abi.encodeCall(IL1AssetRouter.nativeTokenVault, ()), abi.encode(nativeTokenVault));
        vm.mockCall(
            nativeTokenVault,
            abi.encodeCall(IL1NativeTokenVault.chainBalanceBackfillPending, (CHAIN_ID)),
            abi.encode(false)
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

    /*//////////////////////////////////////////////////////////////
                        suspendInterop / resumeInterop
    //////////////////////////////////////////////////////////////*/

    function test_suspendAndResume() public {
        vm.prank(governance);
        messageRoot.enableInterop(CHAIN_ID, false);

        vm.expectEmit(true, false, false, true, address(messageRoot));
        emit IL1MessageRoot.InteropSuspended(CHAIN_ID);
        vm.prank(governance);
        messageRoot.suspendInterop(CHAIN_ID);

        assertTrue(messageRoot.isInteropSuspended(CHAIN_ID));
        assertFalse(messageRoot.isInteropSuspended(OTHER_CHAIN_ID), "other chains untouched");
        assertTrue(messageRoot.isInteropEnabled(CHAIN_ID), "enabling is untouched");

        vm.expectEmit(true, false, false, true, address(messageRoot));
        emit IL1MessageRoot.InteropResumed(CHAIN_ID);
        vm.prank(governance);
        messageRoot.resumeInterop(CHAIN_ID);

        assertFalse(messageRoot.isInteropSuspended(CHAIN_ID));
        assertTrue(messageRoot.isInteropEnabled(CHAIN_ID));
    }

    /// @dev Suspension and enabling are independent: a suspended chain can still be enabled, once.
    function test_enableInteropUnaffectedBySuspension() public {
        vm.prank(governance);
        messageRoot.suspendInterop(CHAIN_ID);

        vm.prank(governance);
        messageRoot.enableInterop(CHAIN_ID, false);
        assertTrue(messageRoot.isInteropEnabled(CHAIN_ID));
        assertTrue(messageRoot.isInteropSuspended(CHAIN_ID));

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(InteropAlreadyEnabled.selector, CHAIN_ID));
        messageRoot.enableInterop(CHAIN_ID, false);
    }

    function test_suspendInterop_revertWhen_notBridgehubOwner() public {
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notOwner));
        messageRoot.suspendInterop(CHAIN_ID);
        assertFalse(messageRoot.isInteropSuspended(CHAIN_ID));
    }

    function test_resumeInterop_revertWhen_notBridgehubOwner() public {
        vm.prank(governance);
        messageRoot.suspendInterop(CHAIN_ID);

        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notOwner));
        messageRoot.resumeInterop(CHAIN_ID);
        assertTrue(messageRoot.isInteropSuspended(CHAIN_ID));
    }

    function test_suspendInterop_revertWhen_alreadySuspended() public {
        vm.prank(governance);
        messageRoot.suspendInterop(CHAIN_ID);

        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(InteropAlreadySuspended.selector, CHAIN_ID));
        messageRoot.suspendInterop(CHAIN_ID);
    }

    function test_resumeInterop_revertWhen_notSuspended() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(InteropNotSuspended.selector, CHAIN_ID));
        messageRoot.resumeInterop(CHAIN_ID);
    }
}
