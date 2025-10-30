// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/cryptography/EIP712Upgradeable.sol";
import {SignatureCheckerUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/cryptography/SignatureCheckerUpgradeable.sol";
import {SignersNotSorted, SignerNotAuthorized, SignatureNotValid} from "../common/L1ContractErrors.sol";
import {IExecutor} from "./chain-interfaces/IExecutor.sol";
import {ValidatorTimelock} from "./ValidatorTimelock.sol";
import {IValidatorTimelock} from "./IValidatorTimelock.sol";
import {IMultisigCommitter} from "./IMultisigCommitter.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Extended ValidatorTimelock with commit function (optionally) locked
/// behind providing extra signatures from verifiers. 
/// @dev The purpose of this contract is to require multiple verifiers check each
/// commit operation before a sequencer can perform it. Verifiers cannot start 
/// commit operations. Only Committer can call commitBatchesMultisig, but requires 
/// providing extra signatures argument
/// @dev Expected to be deployed as a TransparentUpgradeableProxy.
contract MultisigCommitter is IMultisigCommitter, ValidatorTimelock, EIP712Upgradeable {
	/// @dev EIP-712 TypeHash for commitBatchesMultisig
    bytes32 internal constant COMMIT_BATCHES_MULTISIG_TYPEHASH =
        keccak256("CommitBatchesMultisig(address chainAddress,uint256 processBatchFrom,uint256 processBatchTo,bytes batchData)");

	bytes32 public constant override COMMIT_VERIFIER_ROLE = keccak256("COMMIT_VERIFIER_ROLE");

	mapping(address chainAddress => uint256 signingThreshold) public signingThreshold;

	constructor(address _bridgehubAddr) ValidatorTimelock(_bridgehubAddr) {
		_disableInitializers();
	}

	/// @inheritdoc IValidatorTimelock
	function initialize(address _initialOwner, uint32 _initialExecutionDelay) external override(ValidatorTimelock, IValidatorTimelock) initializer {
		__ValidatorTimelock_init(_initialOwner, _initialExecutionDelay);
		__EIP712_init("MultisigCommitter", "1");
	}

	/// @inheritdoc IValidatorTimelock
    function commitBatchesSharedBridge(
		address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _batchData
	) public override(ValidatorTimelock, IValidatorTimelock) {
		require(signingThreshold[_chainAddress] == 0, "Chain requires verifiers signatures for commit");
		super.commitBatchesSharedBridge(_chainAddress, _processBatchFrom, _processBatchTo, _batchData);
	}

	/// @inheritdoc IMultisigCommitter
	function commitBatchesMultisig(
        address chainAddress,
        uint256 processBatchFrom,
        uint256 processBatchTo,
        bytes calldata batchData,
		address[] calldata signers,
		bytes[] calldata signatures
    ) external onlyRole(chainAddress, COMMITTER_ROLE) {
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(COMMIT_BATCHES_MULTISIG_TYPEHASH, chainAddress, processBatchFrom, processBatchTo, keccak256(batchData))));
		_checkSignatures(chainAddress, signers, signatures, digest);
		// signatures validated, follow normal commitBatchesSharedBridge flow
		_recordBatchCommitment(chainAddress, processBatchFrom, processBatchTo);
		// we cannot use _propagateToZKChain here, because function signature is altered
		IExecutor(chainAddress).commitBatchesSharedBridge(chainAddress, processBatchFrom, processBatchTo, batchData);
    }

	/// @inheritdoc IMultisigCommitter
	function setSigningThreshold(address chainAddress, uint256 _signingThreshold) external onlyRole(chainAddress, getRoleAdmin(chainAddress, COMMIT_VERIFIER_ROLE)) {
		signingThreshold[chainAddress] = _signingThreshold;
		emit NewSigningThreshold(chainAddress, _signingThreshold);
	}
	

	function _checkSignatures(address chainAddress, address[] calldata signers, bytes[] calldata signatures, bytes32 digest) internal view {
		require(signers.length == signatures.length, "Mismatching signatures length");
		require(signers.length >= signingThreshold[chainAddress], "Not enough signers");

		// signers must be sorted in order to cheaply validate they are not duplicated
		address previousSigner = address(0);
		for (uint256 i = 0; i < signers.length; i++) {
			if(signers[i] <= previousSigner) 
				revert SignersNotSorted();
			if (!hasRole(chainAddress, COMMIT_VERIFIER_ROLE, signers[i])) 
				revert SignerNotAuthorized(signers[i]);
			if (!SignatureCheckerUpgradeable.isValidSignatureNow(signers[i], digest, signatures[i])) 
				revert SignatureNotValid(signers[i]);
			previousSigner = signers[i];
		}
	}
}
