// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {BundleExecutionResult, L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";
import {L2_INTEROP_CENTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {IERC7786GatewaySource} from "contracts/interop/IERC7786GatewaySource.sol";

import {
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

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

        // InteropLibrary.sendMessage forwards directly to L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1
        // (see deploy-scripts/InteropLibrary.sol:326-328). The shared fixture mocks sendToL1 to
        // return bytes32(uint256(1)) (see _SharedL2ContractDeployer.sol:192-196), so the meaningful
        // oracles are (a) the dispatch shape (target + calldata) and (b) the returned-hash plumbing
        // through the library, rather than the real message hash that the mock never produces.
        vm.expectCall(
            L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            abi.encodeCall(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1, (testMessage))
        );

        bytes32 returnedHash = InteropLibrary.sendMessage(testMessage);

        assertEq(returnedHash, bytes32(uint256(1)), "sendMessage must forward sendToL1's mocked return value");
    }
}
