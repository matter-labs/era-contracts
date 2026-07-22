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

    // Attribute assumes that _executionAddress is an ERC-7930 address.
    function executionAddress(bytes calldata _executionAddress) external pure;

    // Attribute assumes that _executionAddress is an ERC-7930 address.
    function unbundlerAddress(bytes calldata _unbundlerAddress) external pure;

    /// @notice Specifies fee payment method for interop calls
    /// @param _useFixed true = pay fixed ZK amount, false = pay operator-set base token amount
    /// @dev This attribute is optional and defaults to `false` (base token fees) when not provided.
    /// @dev Contracts should be able to toggle this flag for Stage1/Stage2 compatibility, this is due to the fact that operator-set base token amount is dependent on operator of the chain, while fixed ZK option is not.
    function useFixedFee(bool _useFixed) external pure;

    /// @notice Marks a bundle as an **atomic interop** leg. When present, the InteropCenter does not
    ///      publish the bundle to L1; instead it appends the bundle's commit value to the interop IMT
    ///      via the AtomicFlowManager (the burn still flows through the normal `initiateIndirectCall`
    ///      path). The destination executes it via `L2InteropHandler.executeAtomicBundle` once every leg
    ///      of the flow is proven committed before the deadline. Bundle-level attribute.
    /// @param _flowPreimage The full `flowId` preimage. The AtomicFlowManager recomputes `flowId` and
    ///      requires this bundle's hash to be one of `legBundleHashes` with this chain as its declared
    ///      source, so a preimage that does not contain the bundle — e.g. built from a stale off-chain
    ///      bundle-hash preview — reverts the send instead of stranding the burned funds.
    /// @param _lowNullifierIndex The low-nullifier slot for this leg's commit value in the IMT.
    function atomicBundle(AtomicFlowPreimage calldata _flowPreimage, uint256 _lowNullifierIndex) external pure;

    /// @notice Specifies a user-provided salt for the interop bundle.
    /// @param _salt Arbitrary 32-byte salt chosen by the sender.
    /// @dev The salt is mixed with `msg.sender` to derive the bundle's `interopBundleSalt`, which guarantees a unique
    ///      bundle hash. Senders should provide a random salt: it keeps the bundle hash unpredictable and thus preserves
    ///      the bundle's privacy. Each salt must be unique per sender: a sender MUST provide a distinct salt for every
    ///      bundle it sends, regardless of the bundle contents.
    /// @dev Omitting this attribute (or passing `bytes32(0)`) is allowed but discouraged: since each salt must be unique
    ///      per sender, a sender can send at most one bundle without a distinct, non-zero salt.
    function interopBundleSalt(bytes32 _salt) external pure;

    /// @notice Parameters of the L1->L2 priority transaction that delivers a message sent from L1.
    /// @param _mintValue The total amount of the destination chain's base token to be minted with the transaction.
    /// It must cover both the transaction fee (base cost) and the value passed with the message (`interopCallValue`).
    /// @param _l2GasLimit The gas limit of the L2 transaction.
    /// @param _l2GasPerPubdataByteLimit The maximum amount of L2 gas that the operator may charge the user per pubdata byte.
    /// @param _refundRecipient The address on the destination chain that receives the fee refund.
    /// If zero, the refund is sent to the (possibly aliased) sender of the message.
    /// @dev This attribute is required for every message sent through the L1InteropCenter and is not supported on L2s.
    function l1ToL2TransactionParams(
        uint256 _mintValue,
        uint256 _l2GasLimit,
        uint256 _l2GasPerPubdataByteLimit,
        address _refundRecipient
    ) external pure;

    /// @notice Factory dependencies to be published with the L1->L2 priority transaction.
    /// @dev This attribute is optional, only supported for direct calls sent through the L1InteropCenter
    /// and is not supported on L2s. For indirect calls the factory dependencies are provided by the
    /// cross-chain sender (e.g. the asset router) instead.
    function factoryDeps(bytes[] calldata _factoryDeps) external pure;
}
