// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {MsgValueMismatch, ZeroAddress} from "contracts/common/L1ContractErrors.sol";
import {
    InteroperableAddressChainReferenceNotEmpty,
    IndirectCallCannotCarryValue,
    IndirectCallOnlyToAssetRouter
} from "contracts/interop/InteropErrors.sol";

import {
    L2_BRIDGEHUB_ADDR,
    L2_INTEROP_CENTER,
    L2_ASSET_ROUTER_ADDR
} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {IL2CrossChainSender} from "contracts/bridge/interfaces/IL2CrossChainSender.sol";

/// @title L2InteropIndirectCallValueRegressionTestAbstract
/// @notice Regression tests for the indirect call value handling in InteropCenter.
/// @dev Stateless by design: the router's `initiateIndirectCall` is stubbed per exact
/// `(msg.value, calldata)` tuple via `vm.mockCall` and asserted via `vm.expectCall` — no mock contract,
/// no storage. A deviation in the forwarded value or calldata misses the stub and falls through to the
/// real asset router, which reverts on the garbage payload, so a successful send is itself proof of
/// per-call value attribution.
abstract contract L2InteropIndirectCallValueRegressionTestAbstract is L2InteropTestUtils {
    address internal finalRecipient;

    function setUp() public virtual override {
        super.setUp();
        finalRecipient = makeAddr("finalRecipient");
    }

    /// @dev The exact calldata the InteropCenter sends to the indirect call starter for this test
    /// contract's sends (`interopCallValue` is forced to zero for indirect calls).
    function _starterCalldata(bytes memory _data) internal view returns (bytes memory) {
        return abi.encodeCall(IL2CrossChainSender.initiateIndirectCall, (destinationChainId, address(this), 0, _data));
    }

    /// @dev The starter returned by the stubbed router: forwards `_data` to `_returnedTo` with a zero
    /// `interopCallValue` attribute, mirroring the shape the real router returns.
    function _returnedStarter(
        bytes memory _returnedTo,
        bytes memory _data
    ) internal pure returns (InteropCallStarter memory starter) {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (0));
        starter = InteropCallStarter({to: _returnedTo, data: _data, callAttributes: attrs});
    }

    /// @dev Stubs the router starter for one exact `(msg.value, calldata)` invocation and, via
    /// `vm.expectCall`, requires the send to make it.
    function _stubRouterStarter(uint256 _msgValue, bytes memory _data) internal {
        bytes memory callData = _starterCalldata(_data);
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            _msgValue,
            callData,
            abi.encode(_returnedStarter(InteroperableAddress.formatEvmV1(finalRecipient), _data))
        );
        vm.expectCall(L2_ASSET_ROUTER_ADDR, _msgValue, callData);
    }

    /// @dev One indirect call starter targeting the asset router.
    function _indirectCall(
        uint256 _interopCallValue,
        uint256 _indirectCallMessageValue,
        bytes memory _data
    ) internal pure returns (InteropCallStarter memory) {
        bytes[] memory callAttributes = new bytes[](2);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (_interopCallValue));
        callAttributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (_indirectCallMessageValue));
        return
            InteropCallStarter({
                to: InteroperableAddress.formatEvmV1(L2_ASSET_ROUTER_ADDR),
                data: _data,
                callAttributes: callAttributes
            });
    }

    function _send(InteropCallStarter[] memory _calls, uint256 _value) internal {
        bytes[] memory bundleAttributes = new bytes[](2);
        bundleAttributes[0] = abi.encodeCall(
            IERC7786Attributes.unbundlerAddress,
            (InteroperableAddress.formatEvmV1(UNBUNDLER_ADDRESS))
        );
        bundleAttributes[1] = abi.encodeCall(IERC7786Attributes.useFixedFee, (false));

        L2_INTEROP_CENTER.sendBundle{value: _value}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            _calls,
            _withAtomicBundle(bundleAttributes)
        );
    }

    function test_regression_indirectCallMessageValuePassedCorrectly() public {
        // Indirect calls must not carry destination-side value (IndirectCallCannotCarryValue), so the
        // suite exercises value handling purely through indirectCallMessageValue.
        uint256 indirectCallMessageValue = 50;
        vm.deal(address(this), indirectCallMessageValue);

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _indirectCall(0, indirectCallMessageValue, hex"");

        _stubRouterStarter(indirectCallMessageValue, hex"");
        _send(calls, indirectCallMessageValue);
    }

    /// @notice Test that sending with incorrect msg.value reverts
    /// @dev The total msg.value must equal interopCallValue + indirectCallMessageValue for same base token
    function test_regression_incorrectMsgValueReverts() public {
        uint256 indirectCallMessageValue = 50;
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _indirectCall(0, indirectCallMessageValue, hex"");
        // Stub without expectCall: the too-little branch never reaches the starter.
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            indirectCallMessageValue,
            _starterCalldata(hex""),
            abi.encode(_returnedStarter(InteroperableAddress.formatEvmV1(finalRecipient), hex""))
        );

        // Too little value: the send fails while forwarding indirectCallMessageValue to the starter
        // (bundle assembly precedes the explicit msg.value check), as a plain out-of-funds revert.
        uint256 tooLittle = indirectCallMessageValue - 10;
        vm.deal(address(this), tooLittle);
        vm.expectRevert();
        _send(calls, tooLittle);

        // Too much value.
        uint256 tooMuch = indirectCallMessageValue + 10;
        vm.deal(address(this), tooMuch);
        vm.expectRevert(abi.encodeWithSelector(MsgValueMismatch.selector, indirectCallMessageValue, tooMuch));
        _send(calls, tooMuch);
    }

    /// @notice Test indirect call with zero interopCallValue but non-zero indirectCallMessageValue
    /// @dev This tests the edge case where we only want to pass value to the indirect call
    function test_regression_zeroInteropCallValueWithIndirectValue() public {
        uint256 indirectCallMessageValue = 75;
        vm.deal(address(this), indirectCallMessageValue);

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _indirectCall(0, indirectCallMessageValue, hex"");

        _stubRouterStarter(indirectCallMessageValue, hex"");
        _send(calls, indirectCallMessageValue);
    }

    /// @notice An indirect call carrying destination-side value is rejected outright: on the atomic
    /// timeout path such value would be refunded to `InteropCall.from` (the indirect sender), not the
    /// actual payer, so `InteropCenter` forbids it (see `IndirectCallCannotCarryValue`).
    function test_regression_indirectCallWithInteropValueReverts() public {
        uint256 interopCallValue = 100;
        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _indirectCall(interopCallValue, 0, hex"");

        vm.deal(address(this), interopCallValue);
        vm.expectRevert(abi.encodeWithSelector(IndirectCallCannotCarryValue.selector, interopCallValue));
        _send(calls, interopCallValue);
    }

    /// @notice Test multiple indirect calls in a single bundle
    function test_regression_multipleIndirectCallsInBundle() public {
        uint256 indirectCallMessageValue1 = 50;
        uint256 indirectCallMessageValue2 = 75;
        uint256 totalValue = indirectCallMessageValue1 + indirectCallMessageValue2;
        vm.deal(address(this), totalValue);

        // Distinct payloads make the two invocations distinguishable to the exact-calldata stubs.
        InteropCallStarter[] memory calls = new InteropCallStarter[](2);
        calls[0] = _indirectCall(0, indirectCallMessageValue1, hex"01");
        calls[1] = _indirectCall(0, indirectCallMessageValue2, hex"02");

        _stubRouterStarter(indirectCallMessageValue1, hex"01");
        _stubRouterStarter(indirectCallMessageValue2, hex"02");
        _send(calls, totalValue);
    }

    /// @notice Test mixed bundle with direct and indirect calls
    function test_regression_mixedDirectAndIndirectCalls() public {
        uint256 directCallInteropValue = 100;
        uint256 indirectMsgValue = 50;
        uint256 totalValue = directCallInteropValue + indirectMsgValue;
        vm.deal(address(this), totalValue);

        bytes[] memory directCallAttributes = new bytes[](1);
        directCallAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (directCallInteropValue));

        InteropCallStarter[] memory calls = new InteropCallStarter[](2);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(interopTargetContract),
            data: hex"",
            callAttributes: directCallAttributes
        });
        calls[1] = _indirectCall(0, indirectMsgValue, hex"");

        _stubRouterStarter(indirectMsgValue, hex"");
        _send(calls, totalValue);
    }

    /// @notice The recipient RETURNED by an indirect call starter gets the same validation as a
    /// user-supplied one: a chain-carrying ERC-7930 form is rejected — the bundle-level destination
    /// chain is authoritative, and a smuggled chain reference would otherwise be silently ignored.
    function test_indirectStarterReturnedRecipientWithChainReferenceReverts() public {
        bytes memory chainCarryingTo = InteroperableAddress.formatEvmV1(destinationChainId + 1, finalRecipient);
        uint256 indirectCallMessageValue = 50;

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _indirectCall(0, indirectCallMessageValue, hex"");
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            indirectCallMessageValue,
            _starterCalldata(hex""),
            abi.encode(_returnedStarter(chainCarryingTo, hex""))
        );

        vm.deal(address(this), indirectCallMessageValue);
        vm.expectRevert(abi.encodeWithSelector(InteroperableAddressChainReferenceNotEmpty.selector, chainCarryingTo));
        _send(calls, indirectCallMessageValue);
    }

    /// @notice A zero recipient returned by an indirect call starter is rejected, mirroring the
    /// user-supplied starter check: a call to address(0) could never execute and the collected value
    /// would have no refund path.
    function test_indirectStarterReturnedRecipientZeroAddressReverts() public {
        uint256 indirectCallMessageValue = 50;

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _indirectCall(0, indirectCallMessageValue, hex"");
        vm.mockCall(
            L2_ASSET_ROUTER_ADDR,
            indirectCallMessageValue,
            _starterCalldata(hex""),
            abi.encode(_returnedStarter(InteroperableAddress.formatEvmV1(address(0)), hex""))
        );

        vm.deal(address(this), indirectCallMessageValue);
        vm.expectRevert(ZeroAddress.selector);
        _send(calls, indirectCallMessageValue);
    }

    /// @notice Test indirect call with different base tokens between chains
    /// @dev When destination chain has different base token, interopCallValue is bridged instead of burnt,
    ///      but indirectCallMessageValue is still passed to the indirect call
    function test_regression_differentBaseTokenIndirectCall() public {
        uint256 indirectCallMessageValue = 50;
        _mockDifferentDestinationBaseToken();

        // No burned value in the bundle (indirect calls carry none), so bridgehubDepositBaseToken
        // is never called and needs no mock; msg.value covers only the indirectCallMessageValue.
        vm.deal(address(this), indirectCallMessageValue);

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _indirectCall(0, indirectCallMessageValue, hex"");

        _stubRouterStarter(indirectCallMessageValue, hex"");
        _send(calls, indirectCallMessageValue);
    }

    function test_regression_onlyIndirectCallsDifferentBaseToken() public {
        uint256 indirectCallMessageValue = 100;
        _mockDifferentDestinationBaseToken();

        // NOTE: We do NOT mock bridgehubDepositBaseToken here
        // Before the fix, this would cause a revert because bridgehubDepositBaseToken(0) reverts
        // After the fix, bridgehubDepositBaseToken is not called when _totalBurnedCallsValue=0
        vm.deal(address(this), indirectCallMessageValue);

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = _indirectCall(0, indirectCallMessageValue, hex"");

        _stubRouterStarter(indirectCallMessageValue, hex"");
        // This should NOT revert after the fix
        _send(calls, indirectCallMessageValue);
    }

    /// @notice Test multiple indirect calls with zero interopCallValue targeting different base token chain
    function test_regression_multipleOnlyIndirectCallsDifferentBaseToken() public {
        uint256 indirectCallMessageValue1 = 50;
        uint256 indirectCallMessageValue2 = 75;
        uint256 totalIndirectValue = indirectCallMessageValue1 + indirectCallMessageValue2;
        _mockDifferentDestinationBaseToken();

        vm.deal(address(this), totalIndirectValue);

        // Distinct payloads make the two invocations distinguishable to the exact-calldata stubs.
        InteropCallStarter[] memory calls = new InteropCallStarter[](2);
        calls[0] = _indirectCall(0, indirectCallMessageValue1, hex"01");
        calls[1] = _indirectCall(0, indirectCallMessageValue2, hex"02");

        _stubRouterStarter(indirectCallMessageValue1, hex"01");
        _stubRouterStarter(indirectCallMessageValue2, hex"02");
        // This should NOT revert - total burned value is 0, only indirect values
        _send(calls, totalIndirectValue);
    }

    /// @notice Mixed bundle towards a different-base-token chain: the direct call's burned value goes
    /// through `bridgehubDepositBaseToken`, while the indirect call contributes only its
    /// indirectCallMessageValue (indirect calls carry no destination-side value).
    function test_regression_mixedDirectAndIndirectCallsDifferentBaseToken() public {
        uint256 directCallInteropValue = 100;
        uint256 indirectCallMessageValue = 50;
        bytes32 otherBaseTokenAssetId = _mockDifferentDestinationBaseToken();

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

        bytes[] memory directCallAttributes = new bytes[](1);
        directCallAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (directCallInteropValue));

        InteropCallStarter[] memory calls = new InteropCallStarter[](2);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(interopTargetContract),
            data: hex"",
            callAttributes: directCallAttributes
        });
        calls[1] = _indirectCall(0, indirectCallMessageValue, hex"");

        _stubRouterStarter(indirectCallMessageValue, hex"");
        // With a different base token, msg.value covers only the indirect message value.
        _send(calls, indirectCallMessageValue);
    }

    /// @notice Indirect call starters are restricted to the L2 asset router
    /// (`IndirectCallOnlyToAssetRouter`): the atomic timeout-recovery hook is dispatched to the asset
    /// router only, so any other starter's burn would be unrecoverable on timeout. See
    /// {protocol-docs/interop.md#restrictions}.
    function test_indirectCallToNonRouterTargetReverts() public {
        address nonRouterStarter = makeAddr("nonRouterStarter");
        uint256 indirectCallMessageValue = 50;

        bytes[] memory callAttributes = new bytes[](2);
        callAttributes[0] = abi.encodeCall(IERC7786Attributes.interopCallValue, (0));
        callAttributes[1] = abi.encodeCall(IERC7786Attributes.indirectCall, (indirectCallMessageValue));

        InteropCallStarter[] memory calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(nonRouterStarter),
            data: hex"",
            callAttributes: callAttributes
        });

        vm.deal(address(this), indirectCallMessageValue);
        // Pins the check ordering: if the starter were invoked before the rejection, the send would
        // revert with "starter must not be invoked" instead of the expected error.
        vm.mockCallRevert(
            nonRouterStarter,
            abi.encodeWithSelector(IL2CrossChainSender.initiateIndirectCall.selector),
            "starter must not be invoked"
        );
        vm.expectRevert(abi.encodeWithSelector(IndirectCallOnlyToAssetRouter.selector, nonRouterStarter));
        _send(calls, indirectCallMessageValue);
    }

    /// @dev Points the destination chain at a different base token than the source chain's.
    function _mockDifferentDestinationBaseToken() internal returns (bytes32 otherBaseTokenAssetId) {
        otherBaseTokenAssetId = bytes32(uint256(uint160(makeAddr("otherBaseToken"))));
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
    }
}
