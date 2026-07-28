// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Test} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {MsgValueMismatch, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {
    InteroperableAddressChainReferenceNotEmpty,
    IndirectCallCannotCarryValue
} from "contracts/interop/InteropErrors.sol";

import {
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_INTEROP_CENTER,
    L2_ASSET_ROUTER_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {IL2CrossChainSender} from "contracts/bridge/interfaces/IL2CrossChainSender.sol";

/// @title MockL2CrossChainSender
/// @notice Mock contract for testing indirect call value handling in InteropCenter
contract MockL2CrossChainSender is IL2CrossChainSender {
    uint256 public lastReceivedMsgValue;
    uint256 public lastInteropCallValue;
    uint256 public lastDestinationChainId;
    address public lastOriginalCaller;
    address public returnRecipient;
    uint256 public callCount;
    /// @dev When non-empty, returned verbatim as the starter's `to` — lets tests exercise the
    /// InteropCenter's validation of the RETURNED recipient (malformed / chain-carrying / zero forms).
    bytes public returnToOverride;

    constructor(address _returnRecipient) {
        returnRecipient = _returnRecipient;
    }

    function setReturnToOverride(bytes memory _to) external {
        returnToOverride = _to;
    }

    function initiateIndirectCall(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data
    ) external payable override returns (InteropCallStarter memory interopCallStarter) {
        lastReceivedMsgValue = msg.value;
        lastInteropCallValue = _value;
        lastDestinationChainId = _chainId;
        lastOriginalCaller = _originalCaller;
        callCount++;

        bytes[] memory callAttributes = new bytes[](1);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (_value));

        interopCallStarter = InteropCallStarter({
            to: returnToOverride.length > 0 ? returnToOverride : InteroperableAddress.formatEvmV1(returnRecipient),
            data: _data,
            callAttributes: callAttributes
        });
    }

    receive() external payable {}
}

/// @title L2InteropIndirectCallValueRegressionTestAbstract
/// @notice Regression tests for the indirect call value handling fix in InteropCenter
abstract contract L2InteropIndirectCallValueRegressionTestAbstract is L2InteropTestUtils {
    MockL2CrossChainSender internal mockCrossChainSender;
    address internal finalRecipient;

    function setUp() public virtual override {
        super.setUp();

        finalRecipient = makeAddr("finalRecipient");
        mockCrossChainSender = new MockL2CrossChainSender(finalRecipient);
    }

    function test_regression_indirectCallMessageValuePassedCorrectly() public {
        // Indirect calls must not carry destination-side value (IndirectCallCannotCarryValue), so the
        // suite exercises value handling purely through indirectCallMessageValue.
        uint256 interopCallValue = 0;
        uint256 indirectCallMessageValue = 50;
        uint256 totalValue = interopCallValue + indirectCallMessageValue;

        vm.deal(address(this), totalValue);

        // Build an indirect call with both interopCallValue and indirectCallMessageValue
        bytes[] memory callAttributes = new bytes[](2);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (interopCallValue));
        callAttributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (indirectCallMessageValue));

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(mockCrossChainSender)),
            data: hex"",
            callAttributes: callAttributes
        });

        bytes[] memory bundleAttributes = new bytes[](2);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
        bundleAttributes[1] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));

        vm.recordLogs();

        // Send the bundle with total value = interopCallValue + indirectCallMessageValue
        L2_INTEROP_CENTER.sendBundle{value: totalValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _withAtomicBundle(bundleAttributes)
        );

        // Verify that the mock received the correct indirectCallMessageValue as msg.value
        assertEq(
            mockCrossChainSender.lastReceivedMsgValue(),
            indirectCallMessageValue,
            "MockCrossChainSender should receive indirectCallMessageValue as msg.value"
        );

        // Verify that the interopCallValue was recorded correctly
        assertEq(
            mockCrossChainSender.lastInteropCallValue(),
            interopCallValue,
            "interopCallValue should be passed correctly to initiateIndirectCall"
        );

        // Verify that initiateIndirectCall was called exactly once
        assertEq(mockCrossChainSender.callCount(), 1, "initiateIndirectCall should be called once");
    }

    /// @notice Test that sending with incorrect msg.value reverts
    /// @dev The total msg.value must equal interopCallValue + indirectCallMessageValue for same base token
    function test_regression_incorrectMsgValueReverts() public {
        uint256 indirectCallMessageValue = 50;
        (InteropCallStarter[] memory calls, bytes[] memory bundleAttributes) = _singleIndirectCallInputs(
            0,
            indirectCallMessageValue
        );

        // Too little value: the send fails while forwarding indirectCallMessageValue to the starter
        // (bundle assembly precedes the explicit msg.value check), as a plain out-of-funds revert.
        uint256 tooLittle = indirectCallMessageValue - 10;
        vm.deal(address(this), tooLittle);
        vm.expectRevert();
        L2_INTEROP_CENTER.sendBundle{value: tooLittle}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _withAtomicBundle(bundleAttributes)
        );

        // Too much value.
        uint256 tooMuch = indirectCallMessageValue + 10;
        vm.deal(address(this), tooMuch);
        vm.expectRevert(abi.encodeWithSelector(MsgValueMismatch.selector, indirectCallMessageValue, tooMuch));
        L2_INTEROP_CENTER.sendBundle{value: tooMuch}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _withAtomicBundle(bundleAttributes)
        );
    }

    /// @notice Test indirect call with zero interopCallValue but non-zero indirectCallMessageValue
    /// @dev This tests the edge case where we only want to pass value to the indirect call
    function test_regression_zeroInteropCallValueWithIndirectValue() public {
        uint256 interopCallValue = 0;
        uint256 indirectCallMessageValue = 75;

        vm.deal(address(this), indirectCallMessageValue);

        bytes[] memory callAttributes = new bytes[](2);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (interopCallValue));
        callAttributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (indirectCallMessageValue));

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(mockCrossChainSender)),
            data: hex"",
            callAttributes: callAttributes
        });

        bytes[] memory bundleAttributes = new bytes[](2);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
        bundleAttributes[1] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));

        L2_INTEROP_CENTER.sendBundle{value: indirectCallMessageValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _withAtomicBundle(bundleAttributes)
        );

        // Verify that the mock received the correct indirectCallMessageValue
        assertEq(
            mockCrossChainSender.lastReceivedMsgValue(),
            indirectCallMessageValue,
            "Should receive indirectCallMessageValue even when interopCallValue is zero"
        );
        assertEq(mockCrossChainSender.lastInteropCallValue(), 0, "interopCallValue should be zero");
    }

    /// @notice An indirect call carrying destination-side value is rejected outright: on the atomic
    /// timeout path such value would be refunded to `InteropCall.from` (the indirect sender), not the
    /// actual payer, so `InteropCenter` forbids it (see `IndirectCallCannotCarryValue`).
    function test_regression_indirectCallWithInteropValueReverts() public {
        uint256 interopCallValue = 100;
        (InteropCallStarter[] memory calls, bytes[] memory bundleAttributes) = _singleIndirectCallInputs(
            interopCallValue,
            0
        );

        vm.deal(address(this), interopCallValue);
        vm.expectRevert(abi.encodeWithSelector(IndirectCallCannotCarryValue.selector, interopCallValue));
        L2_INTEROP_CENTER.sendBundle{value: interopCallValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _withAtomicBundle(bundleAttributes)
        );
    }

    /// @notice Test multiple indirect calls in a single bundle
    /// @dev Verifies that values are correctly tracked across multiple calls
    function test_regression_multipleIndirectCallsInBundle() public {
        MockL2CrossChainSender mockCrossChainSender2 = new MockL2CrossChainSender(finalRecipient);

        // Indirect calls carry no destination-side value (IndirectCallCannotCarryValue); the values
        // exercised here are the per-call indirectCallMessageValues.
        uint256 interopCallValue1 = 0;
        uint256 indirectCallMessageValue1 = 50;
        uint256 interopCallValue2 = 0;
        uint256 indirectCallMessageValue2 = 75;

        uint256 totalValue = indirectCallMessageValue1 + indirectCallMessageValue2;

        vm.deal(address(this), totalValue);

        // First indirect call
        bytes[] memory callAttributes1 = new bytes[](2);
        callAttributes1[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (interopCallValue1));
        callAttributes1[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (indirectCallMessageValue1));

        // Second indirect call
        bytes[] memory callAttributes2 = new bytes[](2);
        callAttributes2[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (interopCallValue2));
        callAttributes2[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (indirectCallMessageValue2));

        InteropCallStarter[] memory calls = new InteropCallStarter[](2);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(mockCrossChainSender)),
            data: hex"",
            callAttributes: callAttributes1
        });
        calls[1] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(mockCrossChainSender2)),
            data: hex"",
            callAttributes: callAttributes2
        });

        bytes[] memory bundleAttributes = new bytes[](2);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
        bundleAttributes[1] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));

        L2_INTEROP_CENTER.sendBundle{value: totalValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _withAtomicBundle(bundleAttributes)
        );

        // Verify first mock received correct values
        assertEq(
            mockCrossChainSender.lastReceivedMsgValue(),
            indirectCallMessageValue1,
            "First mock should receive indirectCallMessageValue1"
        );
        assertEq(
            mockCrossChainSender.lastInteropCallValue(),
            interopCallValue1,
            "First mock should receive interopCallValue1"
        );

        // Verify second mock received correct values
        assertEq(
            mockCrossChainSender2.lastReceivedMsgValue(),
            indirectCallMessageValue2,
            "Second mock should receive indirectCallMessageValue2"
        );
        assertEq(
            mockCrossChainSender2.lastInteropCallValue(),
            interopCallValue2,
            "Second mock should receive interopCallValue2"
        );
    }

    /// @notice Test mixed bundle with direct and indirect calls
    /// @dev Verifies correct value handling when bundle contains both direct and indirect calls
    function test_regression_mixedDirectAndIndirectCalls() public {
        uint256 directCallInteropValue = 100;
        uint256 indirectInteropValue = 0; // indirect calls must not carry destination-side value
        uint256 indirectMsgValue = 50;

        uint256 totalValue = directCallInteropValue + indirectInteropValue + indirectMsgValue;

        vm.deal(address(this), totalValue);

        // Direct call (no indirect attribute)
        bytes[] memory directCallAttributes = new bytes[](1);
        directCallAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (directCallInteropValue));

        // Indirect call
        bytes[] memory indirectCallAttributes = new bytes[](2);
        indirectCallAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (indirectInteropValue));
        indirectCallAttributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (indirectMsgValue));

        InteropCallStarter[] memory calls = new InteropCallStarter[](2);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(interopTargetContract),
            data: hex"",
            callAttributes: directCallAttributes
        });
        calls[1] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(mockCrossChainSender)),
            data: hex"",
            callAttributes: indirectCallAttributes
        });

        bytes[] memory bundleAttributes = new bytes[](2);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
        bundleAttributes[1] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));

        L2_INTEROP_CENTER.sendBundle{value: totalValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _withAtomicBundle(bundleAttributes)
        );

        // Verify indirect call mock received correct values
        assertEq(mockCrossChainSender.lastReceivedMsgValue(), indirectMsgValue, "Mock should receive indirectMsgValue");
        assertEq(
            mockCrossChainSender.lastInteropCallValue(),
            indirectInteropValue,
            "Mock should receive indirectInteropValue"
        );
    }

    /// @dev Builds the canonical single-indirect-call sendBundle inputs used by the returned-`to`
    /// validation tests below.
    function _singleIndirectCallInputs(
        uint256 _interopCallValue,
        uint256 _indirectCallMessageValue
    ) internal view returns (InteropCallStarter[] memory calls, bytes[] memory bundleAttributes) {
        bytes[] memory callAttributes = new bytes[](2);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (_interopCallValue));
        callAttributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (_indirectCallMessageValue));

        calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(mockCrossChainSender)),
            data: hex"",
            callAttributes: callAttributes
        });

        bundleAttributes = new bytes[](2);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
        bundleAttributes[1] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));
    }

    /// @notice The recipient RETURNED by an (arbitrary, user-chosen) indirect call starter gets the same
    /// validation as a user-supplied one: a chain-carrying ERC-7930 form is rejected — the bundle-level
    /// destination chain is authoritative, and a smuggled chain reference would otherwise be silently
    /// ignored.
    function test_indirectStarterReturnedRecipientWithChainReferenceReverts() public {
        bytes memory chainCarryingTo = InteroperableAddress.formatEvmV1(destinationChainId + 1, finalRecipient);
        mockCrossChainSender.setReturnToOverride(chainCarryingTo);

        uint256 indirectCallMessageValue = 50;
        (InteropCallStarter[] memory calls, bytes[] memory bundleAttributes) = _singleIndirectCallInputs(
            0,
            indirectCallMessageValue
        );

        vm.deal(address(this), indirectCallMessageValue);
        vm.expectRevert(abi.encodeWithSelector(InteroperableAddressChainReferenceNotEmpty.selector, chainCarryingTo));
        L2_INTEROP_CENTER.sendBundle{value: indirectCallMessageValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _withAtomicBundle(bundleAttributes)
        );
    }

    /// @notice A zero recipient returned by an indirect call starter is rejected, mirroring the
    /// user-supplied starter check: a call to address(0) could never execute and the collected value
    /// would have no refund path.
    function test_indirectStarterReturnedRecipientZeroAddressReverts() public {
        mockCrossChainSender.setReturnToOverride(InteroperableAddress.formatEvmV1(address(0)));

        uint256 indirectCallMessageValue = 50;
        (InteropCallStarter[] memory calls, bytes[] memory bundleAttributes) = _singleIndirectCallInputs(
            0,
            indirectCallMessageValue
        );

        vm.deal(address(this), indirectCallMessageValue);
        vm.expectRevert(ZeroAddress.selector);
        L2_INTEROP_CENTER.sendBundle{value: indirectCallMessageValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _withAtomicBundle(bundleAttributes)
        );
    }

    /// @notice Test indirect call with different base tokens between chains
    /// @dev When destination chain has different base token, interopCallValue is bridged instead of burnt,
    ///      but indirectCallMessageValue is still passed to the indirect call
    function test_regression_differentBaseTokenIndirectCall() public {
        uint256 interopCallValue = 0; // indirect calls must not carry destination-side value
        uint256 indirectCallMessageValue = 50;

        // Set up different base token for destination chain
        bytes32 otherBaseTokenAssetId = bytes32(uint256(uint160(makeAddr("otherBaseToken"))));

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (destinationChainId)),
            abi.encode(otherBaseTokenAssetId)
        );

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (block.chainid)),
            abi.encode(baseTokenAssetId)
        );

        // No burned value in the bundle (indirect calls carry none), so bridgehubDepositBaseToken
        // is never called and needs no mock; msg.value covers only the indirectCallMessageValue.
        vm.deal(address(this), indirectCallMessageValue);

        bytes[] memory callAttributes = new bytes[](2);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (interopCallValue));
        callAttributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (indirectCallMessageValue));

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(mockCrossChainSender)),
            data: hex"",
            callAttributes: callAttributes
        });

        bytes[] memory bundleAttributes = new bytes[](2);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
        bundleAttributes[1] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));

        // With different base tokens, msg.value should equal only indirectCallMessageValue
        L2_INTEROP_CENTER.sendBundle{value: indirectCallMessageValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _withAtomicBundle(bundleAttributes)
        );

        // Verify that the mock still received the correct indirectCallMessageValue
        assertEq(
            mockCrossChainSender.lastReceivedMsgValue(),
            indirectCallMessageValue,
            "Mock should receive indirectCallMessageValue even with different base tokens"
        );
    }

    function test_regression_onlyIndirectCallsDifferentBaseToken() public {
        // Only indirect call, no interopCallValue (burned value = 0)
        uint256 interopCallValue = 0;
        uint256 indirectCallMessageValue = 100;

        // Set up different base token for destination chain
        bytes32 otherBaseTokenAssetId = bytes32(uint256(uint160(makeAddr("otherBaseToken"))));

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (destinationChainId)),
            abi.encode(otherBaseTokenAssetId)
        );

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (block.chainid)),
            abi.encode(baseTokenAssetId)
        );

        // NOTE: We do NOT mock bridgehubDepositBaseToken here
        // Before the fix, this would cause a revert because bridgehubDepositBaseToken(0) reverts
        // After the fix, bridgehubDepositBaseToken is not called when _totalBurnedCallsValue=0

        vm.deal(address(this), indirectCallMessageValue);

        // Build indirect call with interopCallValue = 0 (only indirectCallMessageValue)
        bytes[] memory callAttributes = new bytes[](2);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (interopCallValue));
        callAttributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (indirectCallMessageValue));

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(mockCrossChainSender)),
            data: hex"",
            callAttributes: callAttributes
        });

        bytes[] memory bundleAttributes = new bytes[](2);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
        bundleAttributes[1] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));

        // This should NOT revert after the fix
        // msg.value = indirectCallMessageValue (only indirect value, no burned value)
        L2_INTEROP_CENTER.sendBundle{value: indirectCallMessageValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _withAtomicBundle(bundleAttributes)
        );

        // Verify the indirect call was processed correctly
        assertEq(
            mockCrossChainSender.lastReceivedMsgValue(),
            indirectCallMessageValue,
            "Mock should receive indirectCallMessageValue"
        );
        assertEq(mockCrossChainSender.lastInteropCallValue(), 0, "interopCallValue should be 0");
        assertEq(mockCrossChainSender.callCount(), 1, "initiateIndirectCall should be called once");
    }

    /// @notice Test multiple indirect calls with zero interopCallValue targeting different base token chain
    /// @dev Verifies the fix works for multiple calls in a single bundle
    function test_regression_multipleOnlyIndirectCallsDifferentBaseToken() public {
        MockL2CrossChainSender mockCrossChainSender2 = new MockL2CrossChainSender(finalRecipient);

        uint256 indirectCallMessageValue1 = 50;
        uint256 indirectCallMessageValue2 = 75;
        uint256 totalIndirectValue = indirectCallMessageValue1 + indirectCallMessageValue2;

        // Set up different base token for destination chain
        bytes32 otherBaseTokenAssetId = bytes32(uint256(uint160(makeAddr("otherBaseToken"))));

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (destinationChainId)),
            abi.encode(otherBaseTokenAssetId)
        );

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (block.chainid)),
            abi.encode(baseTokenAssetId)
        );

        vm.deal(address(this), totalIndirectValue);

        // First indirect call (interopCallValue = 0)
        bytes[] memory callAttributes1 = new bytes[](2);
        callAttributes1[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (0));
        callAttributes1[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (indirectCallMessageValue1));

        // Second indirect call (interopCallValue = 0)
        bytes[] memory callAttributes2 = new bytes[](2);
        callAttributes2[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (0));
        callAttributes2[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (indirectCallMessageValue2));

        InteropCallStarter[] memory calls = new InteropCallStarter[](2);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(mockCrossChainSender)),
            data: hex"",
            callAttributes: callAttributes1
        });
        calls[1] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(mockCrossChainSender2)),
            data: hex"",
            callAttributes: callAttributes2
        });

        bytes[] memory bundleAttributes = new bytes[](2);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
        bundleAttributes[1] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));

        // This should NOT revert - total burned value is 0, only indirect values
        L2_INTEROP_CENTER.sendBundle{value: totalIndirectValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _withAtomicBundle(bundleAttributes)
        );

        // Verify both indirect calls were processed
        assertEq(
            mockCrossChainSender.lastReceivedMsgValue(),
            indirectCallMessageValue1,
            "First mock should receive correct value"
        );
        assertEq(
            mockCrossChainSender2.lastReceivedMsgValue(),
            indirectCallMessageValue2,
            "Second mock should receive correct value"
        );
    }

    /// @notice Mixed bundle towards a different-base-token chain: the direct call's burned value goes
    /// through `bridgehubDepositBaseToken`, while the indirect call contributes only its
    /// indirectCallMessageValue (indirect calls carry no destination-side value).
    function test_regression_mixedDirectAndIndirectCallsDifferentBaseToken() public {
        uint256 directCallInteropValue = 100;
        uint256 indirectCallMessageValue = 50;

        // Set up different base token for destination chain
        bytes32 otherBaseTokenAssetId = bytes32(uint256(uint160(makeAddr("otherBaseToken"))));

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (destinationChainId)),
            abi.encode(otherBaseTokenAssetId)
        );

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeCall(IBridgehubBase.baseTokenAssetId, (block.chainid)),
            abi.encode(baseTokenAssetId)
        );

        // The direct call's burned value is bridged, not burned locally, so the deposit is mocked.
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSignature(
                "bridgehubDepositBaseToken(uint256,bytes32,address,uint256)",
                destinationChainId,
                otherBaseTokenAssetId,
                address(this),
                directCallInteropValue
            ),
            abi.encode()
        );

        vm.deal(address(this), indirectCallMessageValue);

        // Direct call carrying the burned value.
        bytes[] memory directCallAttributes = new bytes[](1);
        directCallAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (directCallInteropValue));

        // Indirect call carrying only message value.
        bytes[] memory indirectCallAttributes = new bytes[](2);
        indirectCallAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (0));
        indirectCallAttributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (indirectCallMessageValue));

        InteropCallStarter[] memory calls = new InteropCallStarter[](2);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(interopTargetContract),
            data: hex"",
            callAttributes: directCallAttributes
        });
        calls[1] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(mockCrossChainSender)),
            data: hex"",
            callAttributes: indirectCallAttributes
        });

        bytes[] memory bundleAttributes = new bytes[](2);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
        bundleAttributes[1] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));

        // With a different base token, msg.value covers only the indirect message value.
        L2_INTEROP_CENTER.sendBundle{value: indirectCallMessageValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _withAtomicBundle(bundleAttributes)
        );

        assertEq(
            mockCrossChainSender.lastReceivedMsgValue(),
            indirectCallMessageValue,
            "Mock should receive indirectCallMessageValue"
        );
        assertEq(mockCrossChainSender.lastInteropCallValue(), 0, "Indirect call carries no interop value");
    }
}
