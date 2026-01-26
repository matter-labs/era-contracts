// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER,
    L2_INTEROP_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {InteropBundle, MessageInclusionProof} from "contracts/common/Messaging.sol";

import {L2InteropTestUtils, BundleExecutionResult} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

abstract contract L2InteropExecuteBundleTestAbstract is L2InteropTestUtils {
    function test_executeBundleViaReceiveMessage() public {
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        InteropLibrary.sendNative(destinationChainId, interopTargetContract, UNBUNDLER_ADDRESS, 100);
        Vm.Log[] memory logs1 = vm.getRecordedLogs();

        // Verify the first bundle emission
        assertTrue(logs1.length > 0, "Expected logs to be emitted for sendNative");

        bytes memory logsData = extractFirstBundleFromLogs(logs1);
        assertTrue(logsData.length > 0, "Expected bundle data to be extracted");

        (bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle memory interopBundle) = abi.decode(
            logsData,
            (bytes32, bytes32, InteropBundle)
        );

        // Verify the original bundle has valid data
        assertTrue(l2l1MsgHash != bytes32(0), "L2 to L1 message hash should be non-zero");
        assertTrue(interopBundleHash != bytes32(0), "Interop bundle hash should be non-zero");
        assertTrue(interopBundle.calls.length > 0, "Bundle should contain calls");

        bytes memory bundle = abi.encode(interopBundle);
        MessageInclusionProof memory proof = getInclusionProof(L2_INTEROP_CENTER_ADDR, block.chainid);

        vm.recordLogs();

        InteropLibrary.sendDirectCall(
            destinationChainId,
            L2_INTEROP_HANDLER_ADDR,
            abi.encodeCall(L2_INTEROP_HANDLER.executeBundle, (bundle, proof)),
            EXECUTION_ADDRESS,
            UNBUNDLER_ADDRESS
        );
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
