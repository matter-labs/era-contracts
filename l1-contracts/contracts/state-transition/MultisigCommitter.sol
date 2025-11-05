// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/cryptography/EIP712Upgradeable.sol";
import {SignatureCheckerUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/cryptography/SignatureCheckerUpgradeable.sol";
import {EnumerableSetUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/structs/EnumerableSetUpgradeable.sol";
import {SignersNotSorted, SignerNotAuthorized, SignatureNotValid, ChainRequiresVerifiersSignaturesForCommit, SignaturesLengthMismatch, NotEnoughSigners} from "../common/L1ContractErrors.sol";
import {IExecutor} from "./chain-interfaces/IExecutor.sol";
import {ValidatorTimelock} from "./ValidatorTimelock.sol";
import {IValidatorTimelock} from "./IValidatorTimelock.sol";
import {IMultisigCommitter} from "./IMultisigCommitter.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Extended ValidatorTimelock with commit function (optionally) locked
/// behind providing extra signatures from verifiers. By default a shared signing 
/// set is used. Custom signing set with custom threshold can be elected by 
// chainAdmin instead.
/// @dev The purpose of this contract is to require multiple verifiers check each
/// commit operation before a sequencer can perform it. Verifiers cannot start 
/// commit operations. Only Committer can call commitBatchesMultisig, but requires 
/// providing extra signatures argument
/// @dev Expected to be deployed as a TransparentUpgradeableProxy.
contract MultisigCommitter is IMultisigCommitter, ValidatorTimelock, EIP712Upgradeable {
	using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

	/// @dev EIP-712 TypeHash for commitBatchesMultisig
    bytes32 internal constant COMMIT_BATCHES_MULTISIG_TYPEHASH =
        keccak256("CommitBatchesMultisig(address chainAddress,uint256 processBatchFrom,uint256 processBatchTo,bytes batchData)");

	// per chain verifier role, only applies if useCustomVerifiers is set
	bytes32 public constant override COMMIT_VERIFIER_ROLE = keccak256("COMMIT_VERIFIER_ROLE");

	EnumerableSetUpgradeable.AddressSet private sharedVerifiers;
	uint64 public override sharedSigningThreshold;

	struct ChainConfig {
		bool useCustomVerifiers; // if we should use per chain COMMIT_VERIFIER_ROLE holders instead of the shared verifier set
		uint64 signingThreshold; // only applies if useCustomVerifiers is true
	}

	mapping(address chainAddress => ChainConfig) public chainConfig;

	constructor(address _bridgehubAddr) ValidatorTimelock(_bridgehubAddr) {
		_disableInitializers();
	}

	/// @inheritdoc IValidatorTimelock
	function initialize(address _initialOwner, uint32 _initialExecutionDelay) external override(ValidatorTimelock, IValidatorTimelock) initializer {
		_validatorTimelockInit(_initialOwner, _initialExecutionDelay);
		__EIP712_init("MultisigCommitter", "1");
	}

	/// @inheritdoc IValidatorTimelock
    function commitBatchesSharedBridge(
		address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _batchData
	) public override(ValidatorTimelock, IValidatorTimelock) {
		if (getSigningThreshold(_chainAddress) != 0) 
			revert ChainRequiresVerifiersSignaturesForCommit();
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
	function getSigningThreshold(address chainAddress) public override view returns (uint64) {
		if(chainConfig[chainAddress].useCustomVerifiers)
			return chainConfig[chainAddress].signingThreshold;
		else return sharedSigningThreshold;
	}

	/// @inheritdoc IMultisigCommitter
	function isVerifier(address chainAddress, address verifier) public override view returns (bool) {
		if (chainConfig[chainAddress].useCustomVerifiers) 
		return hasRole(chainAddress, COMMIT_VERIFIER_ROLE, verifier);
		else return sharedVerifiers.contains(verifier);
	}

	/// @inheritdoc IMultisigCommitter
	function getVerifiersCount(address chainAddress) external override view returns (uint256) {
		if(chainConfig[chainAddress].useCustomVerifiers)
			return getRoleMemberCount(chainAddress, COMMIT_VERIFIER_ROLE);
		else return sharedVerifiers.length();
	}

	/// @inheritdoc IMultisigCommitter
	function getVerifiersMember(address chainAddress, uint256 index) external override view returns (address) {
		if(chainConfig[chainAddress].useCustomVerifiers)
			return getRoleMember(chainAddress, COMMIT_VERIFIER_ROLE, index);
		else return sharedVerifiers.at(index);
	}

	/// @inheritdoc IMultisigCommitter
	function setSigningThreshold(address chainAddress, uint64 _signingThreshold) external override onlyRole(chainAddress, getRoleAdmin(chainAddress, COMMIT_VERIFIER_ROLE)) {
		chainConfig[chainAddress] = ChainConfig({
			useCustomVerifiers: true,
			signingThreshold: _signingThreshold
		});
		emit NewSigningThreshold(chainAddress, _signingThreshold);
	}

	/// @inheritdoc IMultisigCommitter
	function useSharedSigningSet(address chainAddress) external override onlyRole(chainAddress, getRoleAdmin(chainAddress, COMMIT_VERIFIER_ROLE)) {
		chainConfig[chainAddress] = ChainConfig({
			useCustomVerifiers: false,
			signingThreshold: 0
		});
		emit UseSharedSigningSet(chainAddress);
	}

	/// @inheritdoc IMultisigCommitter
	function setSharedSigningThreshold(uint64 _signingThreshold) external override onlyOwner {
		sharedSigningThreshold = _signingThreshold;
		emit NewSharedSigningThreshold(_signingThreshold);
	}

	/// @inheritdoc IMultisigCommitter
	function addSharedVerifier(address verifier) external override onlyOwner {
		if (!sharedVerifiers.contains(verifier)) {
			// slither-disable-next-line unused-return
			sharedVerifiers.add(verifier);
			emit SharedVerifierAdded(verifier);
		}
		// no-op if verifier is already in the set
	}

	/// @inheritdoc IMultisigCommitter
	function removeSharedVerifier(address verifier) external override onlyOwner {
		if (sharedVerifiers.contains(verifier)) {
			// slither-disable-next-line unused-return
			sharedVerifiers.remove(verifier);
			emit SharedVerifierRemoved(verifier);
		}
		// no-op if verifier is not in the set
	}

	/// @inheritdoc IMultisigCommitter
	function sharedVerifiersCount() external override view returns (uint256) {
		return sharedVerifiers.length();
	}

	/// @inheritdoc IMultisigCommitter
	function sharedVerifiersMember(uint256 index) external override view returns (address) {
		return sharedVerifiers.at(index);
	}

	function _checkSignatures(address chainAddress, address[] calldata signers, bytes[] calldata signatures, bytes32 digest) internal view {
		if (signers.length != signatures.length) 
			revert SignaturesLengthMismatch(signers.length, signatures.length);
		if (signers.length < getSigningThreshold(chainAddress)) 
			revert NotEnoughSigners(signers.length, getSigningThreshold(chainAddress));

		// signers must be sorted in order to cheaply validate they are not duplicated
		address previousSigner = address(0);
		for (uint256 i = 0; i < signers.length; i++) {
			if(signers[i] <= previousSigner) 
				revert SignersNotSorted();
			if (!isVerifier(chainAddress, signers[i])) 
				revert SignerNotAuthorized(signers[i]);
			if (!SignatureCheckerUpgradeable.isValidSignatureNow(signers[i], digest, signatures[i])) 
				revert SignatureNotValid(signers[i]);
			previousSigner = signers[i];
		}
	}
}
