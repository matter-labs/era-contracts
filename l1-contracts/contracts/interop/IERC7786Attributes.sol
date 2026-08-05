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
    ///      most once, so the salt must be fresh per bundle. Omitting it (salt 0) works at most once per
    ///      sender. See {protocol-docs/interop.md#replay-protection-and-bundle-uniqueness}.
    function interopBundleSalt(bytes32 _salt) external pure;

    /// @notice Parameters of the L1->L2 priority transaction that delivers a message sent from L1.
    /// @param _mintValue The total amount of the destination chain's base token to be minted with the transaction.
    /// It must cover both the transaction fee (base cost) and the value passed with the message.
    /// @param _l2GasLimit The gas limit of the L2 transaction.
    /// @param _l2GasPerPubdataByteLimit The maximum amount of L2 gas that the operator may charge per pubdata byte.
    /// @param _refundRecipient The address on the destination chain that receives the fee refund. If zero, the
    /// refund is sent to the (possibly aliased) sender of the message.
    /// @dev L1-only: required by the L1InteropCenter and not supported by the L2 InteropCenter.
    function l1ToL2TransactionParams(
        uint256 _mintValue,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        address _refundRecipient
    ) external pure;

    /// @notice Factory dependencies to be published with the L1->L2 priority transaction.
    /// @dev L1-only and direct calls only: for indirect calls the factory dependencies are provided by the
    /// cross-chain sender. Not supported by the L2 InteropCenter.
    function factoryDeps(bytes[] calldata _factoryDeps) external pure;
}
