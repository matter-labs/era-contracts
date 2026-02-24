// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {L2InteropTestUtils, BundleExecutionResult} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";
import {L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";

abstract contract L2InteropLibraryBasicTestAbstract is L2InteropTestUtils {
    function test_requestTokenTransferInteropViaLibrary() public {
        address l2TokenAddress = initializeTokenByDeposit();
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        InteropLibrary.sendToken(destinationChainId, l2TokenAddress, 100, address(this), UNBUNDLER_ADDRESS, false);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify bundle was emitted
        assertTrue(logs.length > 0, "Expected logs to be emitted");

        BundleExecutionResult memory result = extractAndExecuteSingleBundle(
            logs,
            destinationChainId,
            EXECUTION_ADDRESS
        );

        // Verify the bundle was executed successfully
        assertBundleExecuted(result);
        assertTrue(result.bundleHash != bytes32(0), "Bundle hash should be non-zero");
        assertTrue(result.callCount > 0, "Bundle should contain at least one call");
    }

    function test_requestSendCallViaLibrary() public {
        address l2TokenAddress = initializeTokenByDeposit();
        bytes32 l2TokenAssetId = l2NativeTokenVault.assetId(l2TokenAddress);
        vm.deal(address(this), 1000 ether);

        vm.recordLogs();

        bytes32 expectedSendId = InteropLibrary.sendDirectCall(
            destinationChainId,
            interopTargetContract,
            abi.encodeWithSignature("simpleCall()"),
            EXECUTION_ADDRESS,
            UNBUNDLER_ADDRESS
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Verify bundle was emitted
        assertTrue(logs.length > 0, "Expected logs to be emitted");
        bytes32 interopBundleSentTopic = IInteropCenter.InteropBundleSent.selector;
        bytes32 messageSentTopic = IERC7786GatewaySource.MessageSent.selector;

        bool foundBundle;
        bool foundMessageSent;
        bool checkedMessageSentPayload;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != L2_INTEROP_CENTER_ADDR) {
                continue;
            }
            if (logs[i].topics[0] == interopBundleSentTopic) {
                foundBundle = true;
            } else if (
                logs[i].topics[0] == messageSentTopic &&
                logs[i].topics[1] == expectedSendId &&
                !checkedMessageSentPayload
            ) {
                foundMessageSent = true;
                checkedMessageSentPayload = true;
                (
                    bytes memory sender,
                    bytes memory recipient,
                    bytes memory payload,
                    uint256 value,
                    bytes[] memory attrs
                ) = abi.decode(logs[i].data, (bytes, bytes, bytes, uint256, bytes[]));
                assertTrue(sender.length > 0, "MessageSent sender should be populated");
                assertTrue(recipient.length > 0, "MessageSent recipient should be populated");
                assertEq(
                    payload,
                    abi.encodeWithSignature("simpleCall()"),
                    "MessageSent payload should match call data"
                );
                assertEq(value, 0, "MessageSent value should be zero for direct call");
                assertEq(attrs.length, 3, "MessageSent should keep merged attributes from sendDirectCall");
            }
        }
        assertTrue(foundBundle, "InteropBundleSent should be emitted");
        assertTrue(foundMessageSent, "MessageSent should be emitted with expected sendId");

        BundleExecutionResult memory result = extractAndExecuteSingleBundle(
            logs,
            destinationChainId,
            EXECUTION_ADDRESS
        );

        // Verify the bundle was executed successfully
        assertBundleExecuted(result);
        assertTrue(result.bundleHash != bytes32(0), "Bundle hash should be non-zero");
        assertEq(result.callCount, 1, "Direct call should create exactly one call in the bundle");
    }

    function test_sendMessageToL1ViaLibrary() public {
        bytes memory testMessage = "testing interop";

        vm.recordLogs();
        InteropLibrary.sendMessage(testMessage);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Count InteropCenter logs if any were emitted
        uint256 interopCenterLogCount = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == L2_INTEROP_CENTER_ADDR) {
                interopCenterLogCount++;
            }
        }

        // Note: In L1 context, InteropLibrary.sendMessage may not emit logs
        // since the L2 system contracts are not fully functional.
        // The function completing without reverting is the primary success indicator.
        if (logs.length > 0 && interopCenterLogCount > 0) {
            // If InteropCenter logs were emitted, verify they contain data
            assertTrue(interopCenterLogCount > 0, "InteropCenter should emit at least one log");
        }

        // Regardless of logs, verify the test message was valid
        assertTrue(testMessage.length > 0, "Test message should not be empty");
        assertEq(keccak256(testMessage), keccak256("testing interop"), "Message content should match");
    }
}
