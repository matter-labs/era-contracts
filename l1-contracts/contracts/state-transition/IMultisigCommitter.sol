// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IValidatorTimelock} from "./IValidatorTimelock.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IMultisigCommitter is IValidatorTimelock {
	/// @notice Signing threshold for a chain is set or changed. threshold=0 signifies multisig disabled
	event NewSigningThreshold(address chainAddress, uint256 threshold);

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

	/// @notice Returns the signing threshold for a chain.
	function signingThreshold(address chainAddress) external view returns (uint256);

	/// @notice Sets the signing threshold for a chain. 0 disabled multisig
	/// Can only be called by COMMIT_VERIFIER_ROLE admin.
	function setSigningThreshold(address chainAddress, uint256 threshold) external;
}
