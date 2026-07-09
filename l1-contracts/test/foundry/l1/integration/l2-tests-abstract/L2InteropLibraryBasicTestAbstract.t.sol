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
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {
    CannotInitiateInteropOnL1,
    DirectCallToL1NotSupported,
    MultiCallToL1NotSupported,
    NonZeroValueToL1NotSupported
} from "contracts/interop/InteropErrors.sol";

import {
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

abstract contract L2InteropLibraryBasicTestAbstract is L2InteropTestUtils {
    function test_requestTokenTransferInteropViaLibrary() public {
        address l2TokenAddress = initializeTokenByDeposit();
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        InteropLibrary.sendToken(
            destinationChainId,
            l2TokenAddress,
            100,
            address(this),
            UNBUNDLER_ADDRESS,
            false,
            bytes32(0)
        );
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
            UNBUNDLER_ADDRESS,
            bytes32(0)
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

    /*//////////////////////////////////////////////////////////////
                    L1-DESTINATION SEND CONSTRAINTS
    //////////////////////////////////////////////////////////////*/
    // An L2->L1 bundle must be exactly one indirect, zero-value call. These assert the send-time guards that
    // `InteropCenter` enforces for an L1 destination (the checks had no direct coverage before).

    /// @notice Happy path: a single-call token withdrawal to L1 sends successfully and emits `InteropBundleSent`.
    /// The L1 destination is not registered as an interop chain, so this also exercises the L1 base-token asset-ID
    /// branch on the send side.
    function test_sendToken_ToL1_Succeeds() public {
        address l2TokenAddress = initializeTokenByDeposit();
        vm.deal(address(this), 1000 ether);
        vm.recordLogs();

        bytes32 bundleHash = InteropLibrary.sendToken(
            L1_CHAIN_ID,
            l2TokenAddress,
            100,
            address(this),
            UNBUNDLER_ADDRESS,
            false,
            bytes32(0)
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertTrue(bundleHash != bytes32(0), "L1-destined bundle should return a non-zero hash");
        bool foundBundle;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].emitter == L2_INTEROP_CENTER_ADDR &&
                logs[i].topics[0] == IInteropCenter.InteropBundleSent.selector
            ) {
                foundBundle = true;
                break;
            }
        }
        assertTrue(foundBundle, "InteropBundleSent should be emitted for the L1-destined bundle");
    }

    /// @notice A bundle to L1 with more than one call is rejected: an L1-destined bundle is a single call.
    function test_sendBundle_RevertWhen_MultiCallToL1() public {
        InteropCallStarter[] memory calls = new InteropCallStarter[](2);
        calls[0] = _l1CallStarter(true, 0);
        calls[1] = _l1CallStarter(true, 0);
        vm.expectRevert(abi.encodeWithSelector(MultiCallToL1NotSupported.selector, uint256(2)));
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, _l1BundleAttributes());
    }

    /// @notice A direct (non-indirect) call to L1 is rejected: L1 calls must be indirect (asset-router routed).
    function test_sendBundle_RevertWhen_DirectCallToL1() public {
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _l1CallStarter(false, 0);
        vm.expectRevert(DirectCallToL1NotSupported.selector);
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, _l1BundleAttributes());
    }

    /// @notice An L1 call carrying non-zero destination-side value is rejected: the amount must ride in the payload.
    function test_sendBundle_RevertWhen_NonZeroValueToL1() public {
        uint256 callValue = 5;
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _l1CallStarter(true, callValue);
        vm.expectRevert(abi.encodeWithSelector(NonZeroValueToL1NotSupported.selector, callValue));
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, _l1BundleAttributes());
    }

    /// @notice Interop can never be initiated from L1 itself, regardless of destination.
    function test_sendBundle_RevertWhen_InitiatedOnL1() public {
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _l1CallStarter(true, 0);
        // Pretend the InteropCenter is running on L1.
        vm.chainId(L1_CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(CannotInitiateInteropOnL1.selector, L1_CHAIN_ID));
        l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(L1_CHAIN_ID), calls, _l1BundleAttributes());
    }

    /// @dev Builds a single L1-destined call starter. `_indirect` toggles the ERC-7786 indirectCall attribute;
    /// `_callValue` (when non-zero) adds an interopCallValue attribute. The target is a placeholder — these are
    /// only used for send-time rejection tests.
    function _l1CallStarter(bool _indirect, uint256 _callValue) internal view returns (InteropCallStarter memory) {
        uint256 n;
        if (_indirect) ++n;
        if (_callValue != 0) ++n;
        bytes[] memory attrs = new bytes[](n);
        uint256 j;
        if (_indirect) attrs[j++] = abi.encodeCall(IERC7786Attributes.indirectCall, (0));
        if (_callValue != 0) attrs[j++] = abi.encodeCall(IERC7786Attributes.interopCallValue, (_callValue));
        return
            InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(interopTargetContract),
                data: hex"",
                callAttributes: attrs
            });
    }

    /// @dev Minimal bundle attributes accepted by `sendBundle` (fee is waived for L1 destinations anyway).
    function _l1BundleAttributes() internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](1);
        attrs[0] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));
    }
}
