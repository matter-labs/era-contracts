// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER,
    L2_INTEROP_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {CallStatus, InteropBundle} from "contracts/common/Messaging.sol";
import {AtomicFinalityProof} from "contracts/atomic-interop/IAtomicInterop.sol";

import {BundleExecutionResult, L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {InteropHandler} from "contracts/interop/InteropHandler.sol";

abstract contract L2InteropUnbundleTestAbstract is L2InteropTestUtils {
    function test_unbundleBundleViaReceiveMessage() public {
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        InteropLibrary.sendNative(destinationChainId, interopTargetContract, UNBUNDLER_ADDRESS, 100, false, bytes32(0));
        Vm.Log[] memory logs1 = vm.getRecordedLogs();

        // Verify the first bundle emission
        assertTrue(logs1.length > 0, "Expected logs to be emitted for sendNative");

        bytes memory logsData = extractFirstBundleFromLogs(logs1);
        assertTrue(logsData.length > 0, "Expected bundle data to be extracted");

        (bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle memory interopBundle) = abi.decode(
            logsData,
            (bytes32, bytes32, InteropBundle)
        );

        // Verify the original bundle has valid data. Atomic bundles are never published to L1, so the
        // InteropBundleSent event carries a zero L2->L1 message hash; only the interop bundle hash is set.
        assertEq(l2l1MsgHash, bytes32(0), "Atomic bundle should have no L2->L1 message hash");
        assertTrue(interopBundleHash != bytes32(0), "Interop bundle hash should be non-zero");

        bytes memory bundle = abi.encode(interopBundle);
        // Atomic interop: finality is proven via the AtomicFlowManager IMT gate (mocked in setUp), so a
        // default AtomicFinalityProof suffices and the cross-chain binding is the bundle's sourceChainId.
        AtomicFinalityProof memory proof;

        // Calculate bundle hash for assertions
        bytes32 bundleHash = InteropDataEncoding.encodeInteropBundleHash(interopBundle.sourceChainId, bundle);

        vm.chainId(destinationChainId);
        L2_INTEROP_HANDLER.verifyBundle(bundle, proof);

        // Verify bundle status is Verified after verifyBundle call
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(bundleHash)),
            1,
            "Bundle status should be Verified after verifyBundle"
        );

        vm.chainId(originalChainId);

        vm.recordLogs();

        CallStatus[] memory callStatuses = new CallStatus[](1);
        callStatuses[0] = CallStatus.Executed;
        vm.prank(UNBUNDLER_ADDRESS);
        InteropLibrary.sendDirectCall(
            destinationChainId,
            L2_INTEROP_HANDLER_ADDR,
            abi.encodeCall(L2_INTEROP_HANDLER.unbundleBundle, (bundle, callStatuses)),
            UNBUNDLER_ADDRESS,
            UNBUNDLER_ADDRESS,
            bytes32(0)
        );
        Vm.Log[] memory logs2 = vm.getRecordedLogs();

        // Verify the unbundle bundle emission
        assertTrue(logs2.length > 0, "Expected logs to be emitted for unbundleBundle call");

        BundleExecutionResult memory result = extractAndExecuteSingleBundle(
            logs2,
            destinationChainId,
            UNBUNDLER_ADDRESS
        );

        // Verify the wrapper bundle was executed successfully
        assertBundleExecuted(result);
        assertTrue(result.bundleHash != bytes32(0), "Wrapper bundle hash should be non-zero");

        // Verify the original bundle status is Unbundled (value 3)
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(bundleHash)),
            3,
            "Original bundle status should be Unbundled"
        );

        // Verify call status of the original bundle is Executed (value 1)
        assertEq(
            uint256(InteropHandler(L2_INTEROP_HANDLER_ADDR).callStatus(bundleHash, 0)),
            1,
            "Original bundle call 0 status should be Executed"
        );
    }
}
