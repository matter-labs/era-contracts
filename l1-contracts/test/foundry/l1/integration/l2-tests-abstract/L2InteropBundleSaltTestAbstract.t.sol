// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {Vm} from "forge-std/Vm.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";

import {IInteropCenter} from "contracts/interop/IInteropCenter.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {BundleAttributes, InteropBundle, InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {AttributeAlreadySet, AttributeViolatesRestriction} from "contracts/interop/InteropErrors.sol";
import {L2_SYSTEM_CONTEXT_SYSTEM_CONTRACT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

/// @title L2InteropBundleSaltTestAbstract
/// @notice Tests for the user-provided `interopBundleSalt` bundle attribute.
/// @dev The salt replaces the previously used per-sender interop nonce. The `interopBundleSalt` of the resulting
///      `InteropBundle` is derived as `keccak256(abi.encodePacked(msg.sender, userSalt))`, which keeps bundle hashes
///      unique across senders while letting a sender control uniqueness of their own bundles.
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

    /// @notice Builds bundle attributes containing only the salt attribute (when `_includeSalt` is true).
    function _buildBundleAttributesWithSalt(
        bytes32 _salt,
        bool _includeSalt
    ) internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](_includeSalt ? 1 : 0);
        if (_includeSalt) {
            attrs[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (_salt));
        }
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

    /// @notice When the salt attribute is omitted, the salt defaults to `bytes32(0)`.
    function test_sendBundle_defaultsSaltToZeroWhenAttributeOmitted() public {
        _setupGatewayMode();
        address sender = makeAddr("noSaltSender");

        (InteropBundle memory bundle, ) = _sendAndDecodeBundle(sender, _buildBundleAttributesWithSalt(0, false));

        assertEq(bundle.bundleAttributes.salt, bytes32(0), "salt should default to zero");
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

    /// @notice Edge case: the same sender re-sending an identical bundle with the same salt produces the same hash.
    /// @dev This documents that, unlike the removed auto-incrementing nonce, the user is now responsible for choosing
    ///      a fresh salt to make repeated bundles unique.
    function test_sendBundle_sameSenderSameSaltSameContentCollides() public {
        _setupGatewayMode();
        address sender = makeAddr("saltSender");
        bytes32 userSalt = keccak256("repeated-salt");

        (, bytes32 hash1) = _sendAndDecodeBundle(sender, _buildBundleAttributesWithSalt(userSalt, true));
        (, bytes32 hash2) = _sendAndDecodeBundle(sender, _buildBundleAttributesWithSalt(userSalt, true));

        assertEq(hash1, hash2, "identical bundle with identical salt must collide");
    }

    /// @notice Different senders supplying the same user salt still produce distinct `interopBundleSalt` values.
    /// @dev This is the cross-sender collision protection provided by mixing in `msg.sender`.
    function test_sendBundle_differentSendersSameSaltProduceDifferentInteropSalts() public {
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
