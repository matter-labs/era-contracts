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

/* Coverage improvement suggestions

  Happy-path

  1. test_sendDirectCallViaLibrary_withCallData — the existing test_requestSendCallViaLibrary uses simpleCall() with no args. Add a sibling that
  passes calldata containing function args + factoryDeps, then verifies the MessageSent.payload round-trips byte-for-byte. Catches "library
  serialises calldata wrong" regressions specific to ABI tail handling.
  2. test_sendMessageToL1ViaLibrary_largeMessage — call InteropLibrary.sendMessage with a >1 KiB message; same vm.expectCall shape as the patched
  test. Locks the calldata-encoding path against gas/ABI surprises at non-trivial sizes.

  Unhappy-path

  3. test_sendTokenViaLibrary_revertWhen_zeroAmount — call InteropLibrary.sendToken(..., 0, ...), expect the underlying revert (whichever the
  asset-router / NTV throws for zero-amount transfers). Today the test uses 100 and never exercises the boundary.
  4. test_sendTokenViaLibrary_revertWhen_uninitializedToken — call without first running initializeTokenByDeposit; verify the library propagates the
   asset-not-registered revert. Locks behavior against silent fallthrough.
  5. test_sendDirectCallViaLibrary_revertWhen_executorIsZero — pass address(0) as EXECUTION_ADDRESS; expect the InteropCenter's argument-validation
  revert.

  Edge cases

  6. test_sendMessageToL1ViaLibrary_emptyMessage — call with bytes(""). Decide intent: if the messenger accepts empty, assert the dispatch shape
  with vm.expectCall(... abi.encodeCall(... ("")); if it should revert, lock the revert. Today the test only uses "testing interop".
  7. test_sendDirectCallViaLibrary_attrsCount — the existing test asserts attrs.length == 3. Pin the contents of the attribute slots (e.g., the
  merged execution / unbundler addresses encoded in attrs[0..2]) so silent attribute reordering or omission is caught.

  Adversarial

  8. test_sendTokenViaLibrary_revertOnRecipientAliasing — pass address(this) as the recipient with EXECUTION_ADDRESS resolving to a different alias;
   verify the library does not silently overwrite recipient. Mostly defensive; unlikely to fire but cheap.

*/