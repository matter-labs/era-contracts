// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, Test, stdStorage} from "forge-std/Test.sol";
import "forge-std/console.sol";

import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {MsgValueMismatch} from "contracts/common/L1ContractErrors.sol";

import {L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_BRIDGEHUB_ADDR, L2_INTEROP_CENTER, L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

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

    constructor(address _returnRecipient) {
        returnRecipient = _returnRecipient;
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
            to: InteroperableAddress.formatEvmV1(returnRecipient),
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
        uint256 interopCallValue = 100;
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

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );

        vm.recordLogs();

        // Send the bundle with total value = interopCallValue + indirectCallMessageValue
        L2_INTEROP_CENTER.sendBundle{value: totalValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
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
        uint256 interopCallValue = 100;
        uint256 indirectCallMessageValue = 50;
        uint256 correctTotalValue = interopCallValue + indirectCallMessageValue;

        // Build an indirect call
        bytes[] memory callAttributes = new bytes[](2);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (interopCallValue));
        callAttributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (indirectCallMessageValue));

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(mockCrossChainSender)),
            data: hex"",
            callAttributes: callAttributes
        });

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );

        // Test with only interopCallValue (missing indirectCallMessageValue)
        vm.deal(address(this), interopCallValue);
        vm.expectRevert(abi.encodeWithSelector(MsgValueMismatch.selector, correctTotalValue, interopCallValue));
        L2_INTEROP_CENTER.sendBundle{value: interopCallValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Test with only indirectCallMessageValue (missing interopCallValue)
        vm.deal(address(this), indirectCallMessageValue);
        vm.expectRevert(abi.encodeWithSelector(MsgValueMismatch.selector, correctTotalValue, indirectCallMessageValue));
        L2_INTEROP_CENTER.sendBundle{value: indirectCallMessageValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
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

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );

        L2_INTEROP_CENTER.sendBundle{value: indirectCallMessageValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Verify that the mock received the correct indirectCallMessageValue
        assertEq(
            mockCrossChainSender.lastReceivedMsgValue(),
            indirectCallMessageValue,
            "Should receive indirectCallMessageValue even when interopCallValue is zero"
        );
        assertEq(mockCrossChainSender.lastInteropCallValue(), 0, "interopCallValue should be zero");
    }

    /// @notice Test indirect call with non-zero interopCallValue but zero indirectCallMessageValue
    /// @dev This tests the edge case where the indirect call doesn't need any msg.value
    function test_regression_nonZeroInteropCallValueWithZeroIndirectValue() public {
        uint256 interopCallValue = 100;
        uint256 indirectCallMessageValue = 0;

        vm.deal(address(this), interopCallValue);

        bytes[] memory callAttributes = new bytes[](2);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (interopCallValue));
        callAttributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (indirectCallMessageValue));

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(address(mockCrossChainSender)),
            data: hex"",
            callAttributes: callAttributes
        });

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );

        L2_INTEROP_CENTER.sendBundle{value: interopCallValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Verify that the mock received zero msg.value
        assertEq(mockCrossChainSender.lastReceivedMsgValue(), 0, "Should receive zero msg.value");
        assertEq(
            mockCrossChainSender.lastInteropCallValue(),
            interopCallValue,
            "interopCallValue should be passed correctly"
        );
    }

    /// @notice Test multiple indirect calls in a single bundle
    /// @dev Verifies that values are correctly tracked across multiple calls
    function test_regression_multipleIndirectCallsInBundle() public {
        MockL2CrossChainSender mockCrossChainSender2 = new MockL2CrossChainSender(finalRecipient);

        uint256 interopCallValue1 = 100;
        uint256 indirectCallMessageValue1 = 50;
        uint256 interopCallValue2 = 200;
        uint256 indirectCallMessageValue2 = 75;

        uint256 totalValue = interopCallValue1 +
            indirectCallMessageValue1 +
            interopCallValue2 +
            indirectCallMessageValue2;

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

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );

        L2_INTEROP_CENTER.sendBundle{value: totalValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
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
        uint256 indirectInteropValue = 150;
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

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );

        L2_INTEROP_CENTER.sendBundle{value: totalValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Verify indirect call mock received correct values
        assertEq(mockCrossChainSender.lastReceivedMsgValue(), indirectMsgValue, "Mock should receive indirectMsgValue");
        assertEq(
            mockCrossChainSender.lastInteropCallValue(),
            indirectInteropValue,
            "Mock should receive indirectInteropValue"
        );
    }

    /// @notice Test indirect call with different base tokens between chains
    /// @dev When destination chain has different base token, interopCallValue is bridged instead of burnt,
    ///      but indirectCallMessageValue is still passed to the indirect call
    function test_regression_differentBaseTokenIndirectCall() public {
        uint256 interopCallValue = 100;
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

        // Mock the bridgehubDepositBaseToken call for bridging
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSignature(
                "bridgehubDepositBaseToken(uint256,bytes32,address,uint256)",
                destinationChainId,
                otherBaseTokenAssetId,
                address(this),
                interopCallValue
            ),
            abi.encode()
        );

        // When base tokens are different, msg.value should only be indirectCallMessageValue
        // because interopCallValue is bridged via ERC20 transfer
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

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );

        // With different base tokens, msg.value should equal only indirectCallMessageValue
        L2_INTEROP_CENTER.sendBundle{value: indirectCallMessageValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
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

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );

        // This should NOT revert after the fix
        // msg.value = indirectCallMessageValue (only indirect value, no burned value)
        L2_INTEROP_CENTER.sendBundle{value: indirectCallMessageValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
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

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );

        // This should NOT revert - total burned value is 0, only indirect values
        L2_INTEROP_CENTER.sendBundle{value: totalIndirectValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
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

    /// @notice Test mixed bundle where only some calls have zero interopCallValue
    /// @dev Ensures the fix only skips bridgehubDepositBaseToken when total burned is 0
    function test_regression_mixedIndirectCallsOneWithZeroInteropValue() public {
        MockL2CrossChainSender mockCrossChainSender2 = new MockL2CrossChainSender(finalRecipient);

        // First call: indirect with interopCallValue = 0
        uint256 interopCallValue1 = 0;
        uint256 indirectCallMessageValue1 = 50;

        // Second call: indirect with interopCallValue > 0
        uint256 interopCallValue2 = 100;
        uint256 indirectCallMessageValue2 = 25;

        uint256 totalBurnedValue = interopCallValue1 + interopCallValue2; // = 100
        uint256 totalIndirectValue = indirectCallMessageValue1 + indirectCallMessageValue2; // = 75

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

        // Mock bridgehubDepositBaseToken since totalBurnedValue > 0
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            abi.encodeWithSignature(
                "bridgehubDepositBaseToken(uint256,bytes32,address,uint256)",
                destinationChainId,
                otherBaseTokenAssetId,
                address(this),
                totalBurnedValue
            ),
            abi.encode()
        );

        vm.deal(address(this), totalIndirectValue);

        // First indirect call (interopCallValue = 0)
        bytes[] memory callAttributes1 = new bytes[](2);
        callAttributes1[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (interopCallValue1));
        callAttributes1[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (indirectCallMessageValue1));

        // Second indirect call (interopCallValue > 0)
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

        bytes[] memory bundleAttributes = new bytes[](1);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );

        // totalBurnedValue = 100, so bridgehubDepositBaseToken SHOULD be called
        L2_INTEROP_CENTER.sendBundle{value: totalIndirectValue}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            bundleAttributes
        );

        // Verify both calls were processed
        assertEq(mockCrossChainSender.lastInteropCallValue(), 0, "First call should have 0 interopCallValue");
        assertEq(
            mockCrossChainSender2.lastInteropCallValue(),
            interopCallValue2,
            "Second call should have non-zero interopCallValue"
        );
    }
}
