// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {BundleAttributes, CallAttributes} from "../common/Messaging.sol";
import {IInteropCenter} from "./IInteropCenter.sol";

/// @title IInteropAttributeParser
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Interface of the stateless {InteropAttributeParser} built-in system contract. The parsing logic was
/// split out of the {InteropCenter} to keep the latter under the EIP-170 runtime code-size limit; the parser
/// holds no state and is deployed at a fixed built-in address so the InteropCenter can call it as a constant.
interface IInteropAttributeParser {
    /// @notice Parses a flat ERC-7786 attribute array into the call- and bundle-level attributes, enforcing the
    /// per-attribute restriction implied by `_restriction`. Reverts on a duplicate, disallowed or unsupported
    /// attribute. Mirrors the semantics `InteropCenter` previously implemented inline.
    /// @param _attributes The raw ERC-7786 attribute entries.
    /// @param _restriction Which attribute set is permitted in this context.
    /// @return callAttributes The parsed call-level attributes.
    /// @return bundleAttributes The parsed bundle-level attributes.
    function parseAttributes(
        bytes[] calldata _attributes,
        IInteropCenter.AttributeParsingRestrictions _restriction
    ) external pure returns (CallAttributes memory callAttributes, BundleAttributes memory bundleAttributes);

    /// @notice Extracts the `atomicBundle` send metadata (the full {AtomicFlowPreimage} plus
    /// `lowNullifierIndex`) from the attributes.
    /// @dev Kept separate from {parseAttributes} so the metadata never enters the cross-chain bundle (which would
    /// make `bundleHash` depend on `flowId` — a circular dependency). Returns `isAtomic = false` if absent.
    /// @param _attributes The raw ERC-7786 attribute entries.
    /// @return atomicSend The parsed atomic-send metadata.
    function parseAtomicSend(
        bytes[] calldata _attributes
    ) external pure returns (IInteropCenter.AtomicSend memory atomicSend);

    /// @notice Checks whether `_attributeSelector` is a supported ERC-7786 interop attribute.
    /// @param _attributeSelector The attribute selector to check.
    /// @return True if supported, false otherwise.
    function supportsAttribute(bytes4 _attributeSelector) external pure returns (bool);
}
