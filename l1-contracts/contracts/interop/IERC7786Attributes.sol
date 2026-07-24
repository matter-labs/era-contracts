// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {AtomicFlowPreimage} from "../atomic-interop/IAtomicInterop.sol";

/// @title IERC7786Attributes
/// @notice Interface for the ERC7786 gateway source
/// @dev When adding/removing a function here the InteropCenter must be updated to reflect the changes.
/// https://github.com/ethereum/ERCs/blob/023a7d657666308568d3d1391c578d5972636093/ERCS/erc-7786.md
interface IERC7786Attributes {
    function indirectCall(uint256 _indirectCallMessageValue) external pure;

    function interopCallValue(uint256 _interopCallValue) external pure;

    /// @dev `_executionAddress` is an ERC-7930 address.
    function executionAddress(bytes calldata _executionAddress) external pure;

    /// @dev `_unbundlerAddress` is an ERC-7930 address.
    function unbundlerAddress(bytes calldata _unbundlerAddress) external pure;

    /// @notice Specifies the fee payment method for interop calls.
    /// @param _useFixed true = fixed ZK fee, false (default) = operator-set base-token fee.
    /// @dev See {protocol-docs/interop.md#fee-model}.
    function useFixedFee(bool _useFixed) external pure;

    /// @notice Marks a bundle as an atomic interop leg (bundle-level attribute): the InteropCenter
    ///      appends the bundle's commit value to the interop IMT instead of publishing it to L1.
    ///      See {protocol-docs/interop.md#atomic-bundles} and {protocol-docs/atomicity/flow.md}.
    /// @param _flowPreimage The full `flowId` preimage; the AtomicFlowManager recomputes `flowId` and
    ///      requires this bundle's hash to be one of its legs, else the send reverts.
    /// @param _lowNullifierIndex The low-nullifier slot for this leg's commit value in the IMT.
    function atomicBundle(AtomicFlowPreimage calldata _flowPreimage, uint256 _lowNullifierIndex) external pure;

    /// @notice Specifies a user-provided salt for the interop bundle.
    /// @param _salt Arbitrary 32-byte salt chosen by the sender.
    /// @dev Mixed with `msg.sender` into `interopBundleSalt`; each (sender, salt) pair may be used at
    ///      most once, and a random salt keeps the bundle hash unpredictable. Omitting it (salt 0) works
    ///      at most once per sender. See {protocol-docs/interop.md#replay-protection-and-bundle-uniqueness}.
    function interopBundleSalt(bytes32 _salt) external pure;
}
