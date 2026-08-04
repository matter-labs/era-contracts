// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {BundleAttributes, CallAttributes} from "../common/Messaging.sol";
import {SUPPORTED_INTEROP_ATTRIBUTES} from "../common/Config.sol";

import {IInteropCenter} from "./IInteropCenter.sol";
import {IInteropAttributeParser} from "./IInteropAttributeParser.sol";
import {IERC7786GatewaySource} from "./IERC7786GatewaySource.sol";
import {IERC7786Attributes} from "./IERC7786Attributes.sol";
import {AttributesDecoder} from "./AttributesDecoder.sol";
import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";
import {AttributeAlreadySet, AttributeViolatesRestriction} from "./InteropErrors.sol";

/// @title InteropAttributeParser
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Stateless helper that parses ERC-7786 interop attributes on behalf of the {InteropCenter}. This logic
/// used to live inline in the InteropCenter, but was split out into its own built-in system contract to keep the
/// InteropCenter under the EIP-170 runtime code-size limit. It holds no state and has no constructor/initializer;
/// it is force-deployed at the fixed `L2_INTEROP_ATTRIBUTE_PARSER_ADDR` and invoked by the InteropCenter as a
/// constant address.
/// @dev Deployed on the L2s only, like the InteropCenter.
contract InteropAttributeParser is IInteropAttributeParser {
    /// @inheritdoc IInteropAttributeParser
    function parseAttributes(
        bytes[] calldata _attributes,
        IInteropCenter.AttributeParsingRestrictions _restriction
    ) public pure returns (CallAttributes memory callAttributes, BundleAttributes memory bundleAttributes) {
        // `callAttributes.indirectCall` defaults to `false` (direct call) via the zero-value of the
        // returned memory struct.
        bytes4[SUPPORTED_INTEROP_ATTRIBUTES] memory attributeSelectors = _getERC7786AttributeSelectors();
        // Per-attribute bitmask of the `AttributeParsingRestrictions` enum values under which the attribute is
        // permitted: bit `b` set => the attribute is allowed when `_restriction == AttributeParsingRestrictions(b)`.
        uint8[SUPPORTED_INTEROP_ATTRIBUTES] memory allowedRestrictions = _getAttributeRestrictionMasks();
        // We can only pass each attribute once.
        bool[SUPPORTED_INTEROP_ATTRIBUTES] memory attributeUsed;

        uint256 attributesLength = _attributes.length;
        for (uint256 i = 0; i < attributesLength; ++i) {
            bytes4 selector = bytes4(_attributes[i]);
            // Reverts `UnsupportedAttribute` if the selector is not one we recognize.
            uint256 idx = _attributeIndex(selector, attributeSelectors);

            require(!attributeUsed[idx], AttributeAlreadySet(selector));
            require(
                (allowedRestrictions[idx] >> uint8(_restriction)) & 1 == 1,
                AttributeViolatesRestriction(selector, uint256(_restriction))
            );
            attributeUsed[idx] = true;

            // Decode the attribute payload into the relevant field. Ordering matches
            // `_getERC7786AttributeSelectors()`.
            if (idx == 0) {
                callAttributes.interopCallValue = AttributesDecoder.decodeUint256(_attributes[i]);
            } else if (idx == 1) {
                callAttributes.indirectCall = true;
                callAttributes.indirectCallMessageValue = AttributesDecoder.decodeUint256(_attributes[i]);
            } else if (idx == 2) {
                bundleAttributes.executionAddress = AttributesDecoder.decodeInteroperableAddress(_attributes[i]);
                _validateOptionalInteroperableAddress(bundleAttributes.executionAddress);
            } else if (idx == 3) {
                bundleAttributes.unbundlerAddress = AttributesDecoder.decodeInteroperableAddress(_attributes[i]);
                _validateOptionalInteroperableAddress(bundleAttributes.unbundlerAddress);
            } else if (idx == 4) {
                bundleAttributes.useFixedFee = AttributesDecoder.decodeBool(_attributes[i]);
            } else if (idx == 5) {
                // The atomic send metadata (the flow preimage plus lowNullifierIndex) is parsed separately via
                // `parseAtomicSend` and NOT stored in `BundleAttributes` — it must stay out of the
                // cross-chain bundle so `bundleHash` does not depend on `flowId` (a circular dependency).
                // Here we only validate it is a permitted, non-duplicate bundle attribute (done above).
                continue;
            } else {
                // idx == 6
                bundleAttributes.salt = AttributesDecoder.decodeBytes32(_attributes[i]);
            }
        }
    }

    /// @inheritdoc IInteropAttributeParser
    function parseAtomicSend(
        bytes[] calldata _attributes
    ) public pure returns (IInteropCenter.AtomicSend memory atomicSend) {
        uint256 attributesLength = _attributes.length;
        for (uint256 i = 0; i < attributesLength; ++i) {
            if (bytes4(_attributes[i]) == IERC7786Attributes.atomicBundle.selector) {
                (atomicSend.flowPreimage, atomicSend.lowNullifierIndex) = AttributesDecoder.decodeAtomicBundle(
                    _attributes[i]
                );
                atomicSend.isAtomic = true;
                // The attribute may appear at most once (`parseAttributes` rejects duplicates), so stop scanning.
                break;
            }
        }
    }

    /// @inheritdoc IInteropAttributeParser
    function supportsAttribute(bytes4 _attributeSelector) external pure returns (bool) {
        bytes4[SUPPORTED_INTEROP_ATTRIBUTES] memory ATTRIBUTE_SELECTORS = _getERC7786AttributeSelectors();
        uint256 attributeSelectorsLength = ATTRIBUTE_SELECTORS.length;
        for (uint256 i = 0; i < attributeSelectorsLength; ++i) {
            if (_attributeSelector == ATTRIBUTE_SELECTORS[i]) {
                return true;
            }
        }
        return false;
    }

    /// @notice Returns the index of `_selector` within the supported-attribute list, reverting
    /// `UnsupportedAttribute` if it is not supported.
    function _attributeIndex(
        bytes4 _selector,
        bytes4[SUPPORTED_INTEROP_ATTRIBUTES] memory _selectors
    ) internal pure returns (uint256) {
        for (uint256 i = 0; i < SUPPORTED_INTEROP_ATTRIBUTES; ++i) {
            if (_selector == _selectors[i]) {
                return i;
            }
        }
        revert IERC7786GatewaySource.UnsupportedAttribute(_selector);
    }

    /// @notice Per-attribute bitmask over the `AttributeParsingRestrictions` enum, indexed identically to
    /// `_getERC7786AttributeSelectors()`. Bit `b` set means the attribute is permitted when the active
    /// restriction equals enum value `b` (0=OnlyInteropCallValue, 1=OnlyCallAttributes, 2=OnlyBundleAttributes,
    /// 3=CallAndBundleAttributes).
    function _getAttributeRestrictionMasks() internal pure returns (uint8[SUPPORTED_INTEROP_ATTRIBUTES] memory) {
        return
            [
                uint8(11), // interopCallValue: OnlyInteropCallValue | OnlyCallAttributes | CallAndBundleAttributes
                10, // indirectCall:       OnlyCallAttributes | CallAndBundleAttributes
                12, // executionAddress:   OnlyBundleAttributes | CallAndBundleAttributes
                12, // unbundlerAddress:   OnlyBundleAttributes | CallAndBundleAttributes
                12, // useFixedFee:        OnlyBundleAttributes | CallAndBundleAttributes
                12, // atomicBundle:       OnlyBundleAttributes | CallAndBundleAttributes
                12 // interopBundleSalt:  OnlyBundleAttributes | CallAndBundleAttributes
            ];
    }

    /// @notice Returns the attribute selectors supported by the InteropCenter, in the canonical order used to
    /// index the restriction masks and decode branches.
    function _getERC7786AttributeSelectors() internal pure returns (bytes4[SUPPORTED_INTEROP_ATTRIBUTES] memory) {
        return
            [
                IERC7786Attributes.interopCallValue.selector,
                IERC7786Attributes.indirectCall.selector,
                IERC7786Attributes.executionAddress.selector,
                IERC7786Attributes.unbundlerAddress.selector,
                IERC7786Attributes.useFixedFee.selector,
                IERC7786Attributes.atomicBundle.selector,
                IERC7786Attributes.interopBundleSalt.selector
            ];
    }

    /// @notice Reverts if the given ERC-7930 interoperable address is non-empty but malformed.
    function _validateOptionalInteroperableAddress(bytes memory _interoperableAddress) internal pure {
        if (_interoperableAddress.length == 0) {
            return;
        }

        // slither-disable-next-line unused-return
        InteroperableAddress.parseEvmV1(_interoperableAddress);
    }
}
