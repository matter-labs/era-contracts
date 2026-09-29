// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

import {L2_INTEROP_HANDLER, L2_INTEROP_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";
import {InteropBundle} from "contracts/common/Messaging.sol";
import {AtomicFinalityProof} from "contracts/atomic-interop/IAtomicInterop.sol";

import {BundleExecutionResult, L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

abstract contract L2InteropExecuteBundleTestAbstract is L2InteropTestUtils {
    function test_executeBundleViaReceiveMessage() public {
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        InteropLibrary.sendNative({
            destinationChainId: destinationChainId,
            recipient: interopTargetContract,
            unbundlerAddress: UNBUNDLER_ADDRESS,
            amount: 100,
            useFixedFee: false,
            salt: bytes32(0)
        });
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
        assertTrue(interopBundle.calls.length > 0, "Bundle should contain calls");

        bytes memory bundle = abi.encode(interopBundle);
        // Atomic interop: the destination-side finality is proven via the AtomicFlowManager IMT gate
        // (mocked in these unit tests), so a default AtomicFinalityProof suffices in the rescue payload.
        AtomicFinalityProof memory proof;

        vm.recordLogs();

        // Distinct salt for the wrapper bundle: both sends originate from `address(this)` and InteropCenter
        // enforces a unique (sender, salt) pair.
        InteropLibrary.sendDirectCall({
            destination: destinationChainId,
            target: L2_INTEROP_HANDLER_ADDR,
            data: abi.encodeCall(L2_INTEROP_HANDLER.executeAtomicBundle, (bundle, proof)),
            executionAddress: EXECUTION_ADDRESS,
            unbundlerAddress: UNBUNDLER_ADDRESS,
            salt: bytes32(uint256(1))
        });
        Vm.Log[] memory logs2 = vm.getRecordedLogs();

        // Verify the wrapped bundle emission
        assertTrue(logs2.length > 0, "Expected logs to be emitted for wrapped executeBundle call");

        BundleExecutionResult memory result = extractAndExecuteSingleBundle(
            logs2,
            destinationChainId,
            EXECUTION_ADDRESS
        );

        // Verify the wrapper bundle was executed successfully
        assertBundleExecuted(result);
        assertTrue(result.bundleHash != bytes32(0), "Wrapper bundle hash should be non-zero");
    }
}
