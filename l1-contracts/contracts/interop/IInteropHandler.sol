// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

import {CallStatus, MessageInclusionProof} from "../common/Messaging.sol";

interface IInteropHandler {
    event BundleVerified(bytes32 indexed bundleHash);

    event BundleExecuted(bytes32 indexed bundleHash);

    event BundleUnbundled(bytes32 indexed bundleHash);

    event CallProcessed(bytes32 indexed bundleHash, uint256 indexed callIndex, CallStatus status);

    event ShadowAccountDeployed(address indexed shadowAccount, uint256 indexed ownerChainId, address indexed ownerAddress);

    function executeBundle(bytes memory _bundle, MessageInclusionProof memory _proof) external;

    function verifyBundle(bytes memory _bundle, MessageInclusionProof memory _proof) external;

    function unbundleBundle(uint256 _sourceChainId, bytes memory _bundle, CallStatus[] calldata _callStatus) external;

    /// @notice Computes the deterministic address of a shadow account for a given owner
    /// @param _ownerChainId The chain ID of the owner
    /// @param _ownerAddress The EVM address of the owner on the source chain
    /// @return The address where the shadow account is/will be deployed
    function getShadowAccountAddress(uint256 _ownerChainId, address _ownerAddress) external view returns (address);

    /// @notice Computes the deterministic address of a shadow account for a given owner on this chain
    /// @param _ownerAddress The EVM address of the owner (assumes block.chainid as the owner's chain)
    /// @return The address where the shadow account is/will be deployed
    function getShadowAccountAddress(address _ownerAddress) external view returns (address);
}
