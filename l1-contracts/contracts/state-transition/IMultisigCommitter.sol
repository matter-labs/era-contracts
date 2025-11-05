// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IValidatorTimelock} from "./IValidatorTimelock.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IMultisigCommitter is IValidatorTimelock {
	/// @notice Signing threshold for a chain is set or changed. Shared signing set is disabled. threshold=0 signifies multisig disabled
	event NewSigningThreshold(address chainAddress, uint256 threshold);

	/// @notice Custom signing set is disabled and shared signing set is used again
	event UseSharedSigningSet(address chainAddress);

	/// @notice Shared signing threshold is set, it applies to all chains using shared set
	event NewSharedSigningThreshold(uint256 threshold);

	/// @notice Shared verifier is added, it applies to all chains using shared set
	event SharedVerifierAdded(address verifier);

	/// @notice Shared verifier is removed, it applies to all chains using shared set
	event SharedVerifierRemoved(address verifier);

	/// @notice The role hash for addresses allowed to verify commits on a chain.
	function COMMIT_VERIFIER_ROLE() external view returns (bytes32);

	/// @notice Validates commit was signed by enough validators, records timestamp
	/// and calls zkChain diamond contract commitBatchesSharedBridge
	function commitBatchesMultisig(
        address chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _batchData,
		address[] calldata signers,
		bytes[] calldata signatures
    ) external;

	/// @notice Returns the signing threshold applicable for a chain. 
	/// Respects custom signing set if used
	function getSigningThreshold(address chainAddress) external view returns (uint64);

	/// @notice Returns true if the verifier is authorized to verify commits on the chain.
	/// Respects custom signing set if used
	function isVerifier(address chainAddress, address verifier) external view returns (bool);

	/// @notice Returns the number of verifiers for a chain. Respects custom signing set if used.
	function getVerifiersCount(address chainAddress) external view returns (uint256);

	/// @notice Returns the verifier at the given index for a chain. Respects custom signing set if used.
	function getVerifiersMember(address chainAddress, uint256 index) external view returns (address);

	/// @notice Returns the shared signing threshold.
	function sharedSigningThreshold() external view returns (uint64);

	/// @notice Sets the signing threshold for a chain. 0 disabled multisig
	/// Disables shared signing set if the chain was using it.
	/// Can only be called by COMMIT_VERIFIER_ROLE admin.
	function setSigningThreshold(address chainAddress, uint64 threshold) external;

	/// @notice Disables custom signing set and enables shared signing set for a chain.
	/// Can only be called by COMMIT_VERIFIER_ROLE admin.
	function useSharedSigningSet(address chainAddress) external;

	/// @notice Sets the shared signing threshold.
	/// Can only be called by owner.
	function setSharedSigningThreshold(uint64 _signingThreshold) external;	

	/// @notice Adds a verifier to the shared signing set.
	/// Can only be called by owner.
	function addSharedVerifier(address verifier) external;

	/// @notice Removes a verifier from the shared signing set.
	/// Can only be called by owner.
	function removeSharedVerifier(address verifier) external;

	/// @notice Returns the number of shared verifiers.
	function sharedVerifiersCount() external view returns (uint256);

	/// @notice Returns the shared verifier at the given index.
	function sharedVerifiersMember(uint256 index) external view returns (address);
}
