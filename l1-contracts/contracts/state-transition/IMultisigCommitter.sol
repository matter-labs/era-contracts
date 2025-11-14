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

	/// @notice Shared validator is added, it applies to all chains using shared set
	event SharedValidatorAdded(address validator);

	/// @notice Shared validator is removed, it applies to all chains using shared set
	event SharedValidatorRemoved(address validator);

	/// @notice The role hash for addresses allowed to verify commits on a chain.
	function COMMIT_VALIDATOR_ROLE() external view returns (bytes32);

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

	/// @notice Returns true if the validator is authorized to verify commits on the chain.
	/// Respects custom signing set if used
	function isValidator(address chainAddress, address validator) external view returns (bool);

	/// @notice Returns the number of validators for a chain. Respects custom signing set if used.
	function getValidatorsCount(address chainAddress) external view returns (uint256);

	/// @notice Returns the validator at the given index for a chain. Respects custom signing set if used.
	function getValidatorsMember(address chainAddress, uint256 index) external view returns (address);

	/// @notice Returns the shared signing threshold.
	function sharedSigningThreshold() external view returns (uint64);

	/// @notice Sets the signing threshold for a chain. 0 disabled multisig
	/// Disables shared signing set if the chain was using it.
	/// Can only be called by COMMIT_VALIDATOR_ROLE admin.
	function setSigningThreshold(address chainAddress, uint64 threshold) external;

	/// @notice Disables custom signing set and enables shared signing set for a chain.
	/// Can only be called by COMMIT_VALIDATOR_ROLE admin.
	function useSharedSigningSet(address chainAddress) external;

	/// @notice Sets the shared signing threshold.
	/// Can only be called by owner.
	function setSharedSigningThreshold(uint64 _signingThreshold) external;	

	/// @notice Adds a validator to the shared signing set.
	/// Can only be called by owner.
	function addSharedValidator(address validator) external;

	/// @notice Removes a validator from the shared signing set.
	/// Can only be called by owner.
	function removeSharedValidator(address validator) external;

	/// @notice Returns the number of shared validators.
	function sharedValidatorsCount() external view returns (uint256);

	/// @notice Returns the shared validator at the given index.
	function sharedValidatorsMember(uint256 index) external view returns (address);

	/// @notice Returns true if the validator is an shared validator
	function isSharedValidator(address validator) external view returns (bool);
}
