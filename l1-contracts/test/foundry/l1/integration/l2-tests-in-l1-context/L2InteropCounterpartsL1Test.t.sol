// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {SERVICE_TRANSACTION_SENDER} from "contracts/common/Config.sol";
import {Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {InteropCounterparts} from "contracts/common/Messaging.sol";
import {IL2Bridgehub} from "contracts/core/bridgehub/IL2Bridgehub.sol";
import {InteropCounterpartsConflict, InvalidInteropCounterparts} from "contracts/interop/InteropErrors.sol";

import {SharedL2OneWayBundles} from "./_SharedL2OneWayBundles.sol";

/// @notice The interop counterparts registry of `L2Bridgehub`. See {protocol-docs/interop.md#counterpart-addressing}.
contract L2InteropCounterpartsL1Test is SharedL2OneWayBundles {
    function _assertCounterparts(uint256 _chainId, address _interopCenter, address _assetRouter) internal view {
        InteropCounterparts memory stored = bridgehub.interopCounterparts(_chainId);
        assertEq(stored.interopCenter, _interopCenter);
        assertEq(stored.assetRouter, _assetRouter);
    }

    /// @notice A chain that did not opt in has no counterparts for any chain, L1 included.
    function test_interopCounterparts_emptyByDefault() public view {
        _assertCounterparts(L1_CHAIN_ID, address(0), address(0));
        _assertCounterparts(WRITER_SOURCE_CHAIN_ID, address(0), address(0));
        _assertCounterparts(INTEROP_DESTINATION_CHAIN_ID, address(0), address(0));
    }

    /// @notice L1 needs no writer: its roots come with the chain's settlement.
    function test_setInteropCounterparts_forL1() public {
        vm.expectEmit(true, false, false, true, address(bridgehub));
        emit IL2Bridgehub.InteropCounterpartsSet(L1_CHAIN_ID, l1InteropCenter, l1AssetRouter);
        _setCounterparts(L1_CHAIN_ID, l1InteropCenter, l1AssetRouter);

        _assertCounterparts(L1_CHAIN_ID, l1InteropCenter, l1AssetRouter);
        assertEq(bridgehub.baseTokenAssetId(L1_CHAIN_ID), bytes32(0), "L1 is not registered as an interop chain");
        assertFalse(bridgehub.isPeerAllowed(L1_CHAIN_ID));
    }

    function test_setInteropCounterparts_forAWriterSource() public {
        _setWriter(WRITER_SOURCE_CHAIN_ID, writer);
        _setCounterparts(WRITER_SOURCE_CHAIN_ID, sourceInteropCenter, sourceAssetRouter);
        _assertCounterparts(WRITER_SOURCE_CHAIN_ID, sourceInteropCenter, sourceAssetRouter);
        assertEq(bridgehub.baseTokenAssetId(WRITER_SOURCE_CHAIN_ID), bytes32(0));

        // Replacing and removing are plain writes.
        address newCenter = makeAddr("newCenter");
        _setCounterparts(WRITER_SOURCE_CHAIN_ID, newCenter, sourceAssetRouter);
        _assertCounterparts(WRITER_SOURCE_CHAIN_ID, newCenter, sourceAssetRouter);

        vm.expectEmit(true, false, false, true, address(bridgehub));
        emit IL2Bridgehub.InteropCounterpartsSet(WRITER_SOURCE_CHAIN_ID, address(0), address(0));
        _setCounterparts(WRITER_SOURCE_CHAIN_ID, address(0), address(0));
        _assertCounterparts(WRITER_SOURCE_CHAIN_ID, address(0), address(0));
    }

    /// @notice The counterparts of a chain other than L1 need the chain to be a writer source: that is the mark the
    /// asset tracker applies the origin rule by. It stays set once the writer is removed.
    function test_setInteropCounterparts_revertWhen_notAWriterSource() public {
        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert(abi.encodeWithSelector(InteropCounterpartsConflict.selector, WRITER_SOURCE_CHAIN_ID));
        bridgehub.setInteropCounterparts(WRITER_SOURCE_CHAIN_ID, sourceInteropCenter, sourceAssetRouter);

        _setWriter(WRITER_SOURCE_CHAIN_ID, writer);
        _setWriter(WRITER_SOURCE_CHAIN_ID, address(0));
        _setCounterparts(WRITER_SOURCE_CHAIN_ID, sourceInteropCenter, sourceAssetRouter);
    }

    function test_setInteropCounterparts_revertWhen_chainIsThisChain() public {
        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert(abi.encodeWithSelector(InteropCounterpartsConflict.selector, block.chainid));
        bridgehub.setInteropCounterparts(block.chainid, sourceInteropCenter, sourceAssetRouter);
    }

    /// @notice A chain is an atomic peer or a one-way counterpart, never both: each registration refuses the other.
    function test_setInteropCounterparts_revertWhen_chainIsAnAllowedPeer() public {
        // The harness allowed this peer; a writer for it does not make it a one-way counterpart.
        _setWriter(INTEROP_DESTINATION_CHAIN_ID, writer);
        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert(abi.encodeWithSelector(InteropCounterpartsConflict.selector, INTEROP_DESTINATION_CHAIN_ID));
        bridgehub.setInteropCounterparts(INTEROP_DESTINATION_CHAIN_ID, sourceInteropCenter, sourceAssetRouter);

        // Once the peer is deregistered, the chain can become a counterpart.
        vm.prank(SERVICE_TRANSACTION_SENDER);
        bridgehub.deregisterChainForInterop(INTEROP_DESTINATION_CHAIN_ID);
        _setCounterparts(INTEROP_DESTINATION_CHAIN_ID, sourceInteropCenter, sourceAssetRouter);
    }

    function test_allowInteropPeer_revertWhen_chainHasCounterparts() public {
        _setWriter(WRITER_SOURCE_CHAIN_ID, writer);
        _setCounterparts(WRITER_SOURCE_CHAIN_ID, sourceInteropCenter, sourceAssetRouter);

        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert(abi.encodeWithSelector(InteropCounterpartsConflict.selector, WRITER_SOURCE_CHAIN_ID));
        bridgehub.allowInteropPeer(WRITER_SOURCE_CHAIN_ID, baseTokenAssetId);

        _setCounterparts(WRITER_SOURCE_CHAIN_ID, address(0), address(0));
        vm.prank(SERVICE_TRANSACTION_SENDER);
        bridgehub.allowInteropPeer(WRITER_SOURCE_CHAIN_ID, baseTokenAssetId);
        assertTrue(bridgehub.isPeerAllowed(WRITER_SOURCE_CHAIN_ID));
    }

    function test_setInteropCounterparts_revertWhen_onlyOneAddress() public {
        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropCounterparts.selector, l1InteropCenter, address(0)));
        bridgehub.setInteropCounterparts(L1_CHAIN_ID, l1InteropCenter, address(0));
        vm.prank(SERVICE_TRANSACTION_SENDER);
        vm.expectRevert(abi.encodeWithSelector(InvalidInteropCounterparts.selector, address(0), l1AssetRouter));
        bridgehub.setInteropCounterparts(L1_CHAIN_ID, address(0), l1AssetRouter);
    }

    /// @notice Only service transactions of L1's `ChainRegistrationSender` write the registry; the chain's own
    /// owner does not.
    function testFuzz_setInteropCounterparts_revertWhen_notChainRegistrationSender(address _caller) public {
        vm.assume(_caller != SERVICE_TRANSACTION_SENDER);
        // The aliased `ChainRegistrationSender` of the harness.
        vm.assume(_caller != address(0x000000000000000000000000000000000002000a));
        vm.prank(_caller);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, _caller));
        bridgehub.setInteropCounterparts(L1_CHAIN_ID, l1InteropCenter, l1AssetRouter);
    }
}
