// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";

import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {BundleAttributes, InteropBundle, InteropCallStarter} from "contracts/common/Messaging.sol";
import {AtomicFlowPreimage} from "contracts/atomic-interop/IAtomicInterop.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {
    AttributeAlreadySet,
    AttributeViolatesRestriction,
    InteropBundleSaltAlreadyUsed,
    InteropPreviewHash,
    NonAtomicSendUnsupported
} from "contracts/interop/InteropErrors.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

/// @title L2InteropBundleSaltTestAbstract
/// @notice Covers the user-provided `interopBundleSalt` bundle attribute: salt derivation, per-sender replay
/// protection, and attribute parsing. See {protocol-docs/interop.md}.
abstract contract L2InteropBundleSaltTestAbstract is L2InteropTestUtils {
    /// @notice Mirrors the salt-derivation logic implemented in `InteropCenter._sendBundle`.
    function _expectedSalt(address _sender, bytes32 _userSalt) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_sender, _userSalt));
    }

    /// @notice Enables gateway mode so that `sendBundle` does not revert.
    function _setupGatewayMode() internal {
        vm.mockCall(
            address(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT),
            abi.encodeWithSelector(L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT.currentSettlementLayerChainId.selector),
            abi.encode(block.chainid)
        );
    }

    /// @notice Builds a single, value-less interop call.
    function _buildSimpleCall() internal view returns (InteropCallStarter[] memory calls) {
        calls = new InteropCallStarter[](1);
        calls[0] = InteropCallStarter({
            to: InteroperableAddress.formatEvmV1(interopTargetContract),
            data: hex"",
            callAttributes: new bytes[](0)
        });
    }

    /// @notice Builds bundle attributes containing the salt attribute (when `_includeSalt` is true) plus the
    ///         mandatory `atomicBundle` attribute (all interop is atomic).
    /// @dev The salt is placed first so that restriction-violation tests, which parse this array under
    ///      `OnlyCallAttributes`, still surface the salt selector as the first offending attribute. The
    ///      atomicBundle flow metadata is a placeholder — the `AtomicFlowManager.append` gate is mocked in
    ///      these unit tests (see {L2InteropTestUtils.setUp}).
    function _buildBundleAttributesWithSalt(
        bytes32 _salt,
        bool _includeSalt
    ) internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](_includeSalt ? 2 : 1);
        uint256 idx = 0;
        if (_includeSalt) {
            attrs[idx++] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (_salt));
        }
        attrs[idx++] = abi.encodeCall(
            IERC7786Attributes.atomicBundle,
            (
                AtomicFlowPreimage({
                    deadline: type(uint64).max,
                    settlementLayerChainId: 0,
                    legBundleHashes: new bytes32[](0),
                    legSourceChainIds: new uint256[](0)
                }),
                uint256(0)
            )
        );
    }

    /// @notice Sends a bundle and returns the `InteropBundle` decoded from the `InteropBundleSent` event.
    function _sendAndDecodeBundle(
        address _sender,
        bytes[] memory _bundleAttributes
    ) internal returns (InteropBundle memory bundle, bytes32 bundleHash) {
        InteropCallStarter[] memory calls = _buildSimpleCall();

        vm.recordLogs();
        vm.prank(_sender);
        bundleHash = l2InteropCenter.sendBundle{value: 0}(
            InteroperableAddress.formatEvmV1(destinationChainId),
            calls,
            _bundleAttributes
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes memory data = extractFirstBundleFromLogs(logs);
        require(data.length != 0, "InteropBundleSent event not found");
        // solhint-disable-next-line no-unused-vars
        (, , bundle) = abi.decode(data, (bytes32, bytes32, InteropBundle));
    }

    /// @notice `previewBundleHash` reports exactly the `bundleHash` the matching `sendBundle` emits, so the
    ///         off-chain atomic `flowId` (which commits to `bundleHash`) can be derived before the real send.
    /// @dev `previewBundleHash` follows the quoter pattern: it ALWAYS reverts with `InteropPreviewHash(hash)`
    ///      (so its stateful assembly can never commit on-chain), and callers read the hash from the revert.
    ///      The anvil-interop helpers rely on this equivalence to build atomic flows. The preview must run
    ///      from the same sender (its address feeds both the salt derivation and each call's `from`) and must
    ///      not consume the salt-uniqueness slot, so the real send below can reuse the same salt.
    /// @notice The PR's headline invariant: an L2->L2 send WITHOUT the `atomicBundle` attribute has no
    /// delivery path (public L1-published L2->L2 interop was removed) and must revert
    /// `NonAtomicSendUnsupported`. This is the asymmetric counterpart to the atomic->L1 rejection
    /// (`AtomicBundleToL1NotSupported`), which already has a negative test.
    /// @dev The atomicity/destination check is the first thing `_sendBundle` does — before any value
    /// collection or bundle assembly — so the revert precedes (and therefore rolls back) any burn.
    function test_sendBundle_revertsWhen_noAtomicBundleAttribute() public {
        _setupGatewayMode();
        InteropCallStarter[] memory calls = _buildSimpleCall();
        // Attributes with ONLY a salt — no `atomicBundle`.
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (keccak256("no-atomic-attr")));

        vm.expectRevert(NonAtomicSendUnsupported.selector);
        l2InteropCenter.sendBundle{value: 0}(InteroperableAddress.formatEvmV1(destinationChainId), calls, attrs);
    }

    function test_previewBundleHash_matchesSentBundleHash() public {
        _setupGatewayMode();
        address sender = makeAddr("previewSender");
        bytes32 userSalt = keccak256("preview-salt-1");
        bytes[] memory attrs = _buildBundleAttributesWithSalt(userSalt, true);
        InteropCallStarter[] memory calls = _buildSimpleCall();
        bytes memory destination = InteroperableAddress.formatEvmV1(destinationChainId);

        vm.prank(sender);
        // Low-level call so we can read the hash out of the quoter revert (see {previewBundleHash}).
        (bool ok, bytes memory ret) = address(l2InteropCenter).call(
            abi.encodeCall(l2InteropCenter.previewBundleHash, (destination, calls, attrs))
        );
        assertFalse(ok, "previewBundleHash must revert with InteropPreviewHash (quoter pattern)");
        assertEq(ret.length, 36, "revert reason must be InteropPreviewHash(bytes32)");
        assertEq(bytes4(ret), InteropPreviewHash.selector, "unexpected preview revert selector");
        bytes32 predicted;
        // ret layout: 4-byte selector followed by the abi-encoded bytes32 hash.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            predicted := mload(add(ret, 0x24))
        }

        (, bytes32 emitted) = _sendAndDecodeBundle(sender, attrs);
        assertEq(predicted, emitted, "previewBundleHash must equal the emitted bundleHash");
    }

    /*//////////////////////////////////////////////////////////////
                        Happy path
    //////////////////////////////////////////////////////////////*/

    /// @notice The user-provided salt is stored in the bundle attributes and mixed into `interopBundleSalt`.
    function test_sendBundle_usesUserProvidedSalt() public {
        _setupGatewayMode();
        address sender = makeAddr("saltSender");
        bytes32 userSalt = keccak256("user-salt-1");

        (InteropBundle memory bundle, ) = _sendAndDecodeBundle(sender, _buildBundleAttributesWithSalt(userSalt, true));

        assertEq(bundle.bundleAttributes.salt, userSalt, "user salt should be stored in bundle attributes");
        assertEq(
            bundle.interopBundleSalt,
            _expectedSalt(sender, userSalt),
            "interopBundleSalt should be derived from sender and user salt"
        );
    }

    /// @notice Omitting the salt attribute is equivalent to passing `bytes32(0)` (usable once per sender).
    function test_sendBundle_omittedSaltAttributeTreatedAsZero() public {
        _setupGatewayMode();
        address sender = makeAddr("noSaltSender");

        (InteropBundle memory bundle, ) = _sendAndDecodeBundle(sender, _buildBundleAttributesWithSalt(0, false));

        assertEq(bundle.bundleAttributes.salt, bytes32(0), "omitted salt attribute should be treated as zero");
        assertEq(
            bundle.interopBundleSalt,
            _expectedSalt(sender, bytes32(0)),
            "interopBundleSalt should be derived from sender and zero salt"
        );
    }

    /*//////////////////////////////////////////////////////////////
                        Uniqueness
    //////////////////////////////////////////////////////////////*/

    /// @notice Two bundles that differ only by the user salt have different bundle hashes.
    function test_sendBundle_differentSaltsProduceDifferentBundleHashes() public {
        _setupGatewayMode();
        address sender = makeAddr("saltSender");

        (, bytes32 hash1) = _sendAndDecodeBundle(sender, _buildBundleAttributesWithSalt(keccak256("a"), true));
        (, bytes32 hash2) = _sendAndDecodeBundle(sender, _buildBundleAttributesWithSalt(keccak256("b"), true));

        assertTrue(hash1 != hash2, "different salts must yield different bundle hashes");
    }

    /// @notice Reusing a (sender, salt) pair reverts with `InteropBundleSaltAlreadyUsed`, even when the new
    /// bundle's content differs.
    function test_sendBundle_revertsWhenSaltReused() public {
        _setupGatewayMode();
        address sender = makeAddr("saltSender");
        bytes32 userSalt = keccak256("repeated-salt");

        _sendAndDecodeBundle(sender, _buildBundleAttributesWithSalt(userSalt, true));
        assertTrue(l2InteropCenter.isInteropBundleSaltUsed(sender, userSalt), "used salt should be recorded");

        InteropCallStarter[] memory calls = _buildSimpleCall();
        bytes[] memory attrs = _buildBundleAttributesWithSalt(userSalt, true);
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(InteropBundleSaltAlreadyUsed.selector, sender, userSalt));
        l2InteropCenter.sendBundle{value: 0}(InteroperableAddress.formatEvmV1(destinationChainId), calls, attrs);
    }

    /// @notice The same sender can send another bundle (even an identical one) as long as it provides a fresh salt.
    function test_sendBundle_freshSaltAllowsResend() public {
        _setupGatewayMode();
        address sender = makeAddr("saltSender");

        (, bytes32 hash1) = _sendAndDecodeBundle(sender, _buildBundleAttributesWithSalt(keccak256("salt-1"), true));
        (, bytes32 hash2) = _sendAndDecodeBundle(sender, _buildBundleAttributesWithSalt(keccak256("salt-2"), true));

        assertTrue(hash1 != hash2, "fresh salt should yield a new bundle hash");
        assertTrue(l2InteropCenter.isInteropBundleSaltUsed(sender, keccak256("salt-1")));
        assertTrue(l2InteropCenter.isInteropBundleSaltUsed(sender, keccak256("salt-2")));
    }

    /// @notice The salt is scoped per-sender: the derived `interopBundleSalt` differs across senders, and the
    /// `isInteropBundleSaltUsed` replay mapping is keyed per (sender, salt).
    function test_sendBundle_sameSaltIsIsolatedPerSender() public {
        _setupGatewayMode();
        address senderA = makeAddr("senderA");
        address senderB = makeAddr("senderB");
        bytes32 userSalt = keccak256("shared-salt");

        (InteropBundle memory bundleA, ) = _sendAndDecodeBundle(
            senderA,
            _buildBundleAttributesWithSalt(userSalt, true)
        );
        (InteropBundle memory bundleB, ) = _sendAndDecodeBundle(
            senderB,
            _buildBundleAttributesWithSalt(userSalt, true)
        );

        assertTrue(
            bundleA.interopBundleSalt != bundleB.interopBundleSalt,
            "different senders must derive different interopBundleSalt even with the same user salt"
        );
        assertEq(bundleA.interopBundleSalt, _expectedSalt(senderA, userSalt));
        assertEq(bundleB.interopBundleSalt, _expectedSalt(senderB, userSalt));

        assertTrue(l2InteropCenter.isInteropBundleSaltUsed(senderA, userSalt));
        assertTrue(l2InteropCenter.isInteropBundleSaltUsed(senderB, userSalt));
    }

    /*//////////////////////////////////////////////////////////////
                        parseAttributes / supportsAttribute
    //////////////////////////////////////////////////////////////*/

    /// @notice `parseAttributes` decodes the salt into the bundle attributes.
    function test_parseAttributes_decodesSalt() public view {
        bytes32 userSalt = keccak256("parsed-salt");
        bytes[] memory attrs = _buildBundleAttributesWithSalt(userSalt, true);

        // solhint-disable-next-line no-unused-vars
        (, BundleAttributes memory bundleAttributes) = l2InteropCenter.parseAttributes(
            attrs,
            IInteropCenter.AttributeParsingRestrictions.OnlyBundleAttributes
        );

        assertEq(bundleAttributes.salt, userSalt, "parseAttributes should decode the salt");
    }

    /// @notice The salt attribute cannot be provided more than once.
    function test_parseAttributes_revertsWhenSaltSetTwice() public {
        bytes[] memory attrs = new bytes[](2);
        attrs[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (keccak256("x")));
        attrs[1] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (keccak256("y")));

        vm.expectRevert(
            abi.encodeWithSelector(AttributeAlreadySet.selector, IERC7786Attributes.interopBundleSalt.selector)
        );
        l2InteropCenter.parseAttributes(attrs, IInteropCenter.AttributeParsingRestrictions.OnlyBundleAttributes);
    }

    /// @notice The salt is a bundle-level attribute and must not be accepted as a call attribute.
    function test_parseAttributes_revertsWhenSaltUsedAsCallAttribute() public {
        bytes[] memory attrs = _buildBundleAttributesWithSalt(keccak256("z"), true);

        vm.expectRevert(
            abi.encodeWithSelector(
                AttributeViolatesRestriction.selector,
                IERC7786Attributes.interopBundleSalt.selector,
                uint256(IInteropCenter.AttributeParsingRestrictions.OnlyCallAttributes)
            )
        );
        l2InteropCenter.parseAttributes(attrs, IInteropCenter.AttributeParsingRestrictions.OnlyCallAttributes);
    }

    /// @notice The salt selector is reported as a supported attribute.
    function test_supportsAttribute_interopBundleSalt() public view {
        assertTrue(l2InteropCenter.supportsAttribute(IERC7786Attributes.interopBundleSalt.selector));
    }
}
