// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";
import {LibMap} from "./libraries/LibMap.sol";
import {IZKChain} from "./chain-interfaces/IZKChain.sol";
import {TimeNotReached, NotAZKChain} from "../common/L1ContractErrors.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {IValidatorTimelock} from "./IValidatorTimelock.sol";
import {IExecutor} from "./chain-interfaces/IExecutor.sol";
import {ValidatorTimelock} from "./ValidatorTimelock.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/cryptography/EIP712Upgradeable.sol";
import {SignatureCheckerUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/cryptography/SignatureCheckerUpgradeable.sol";


//TODO proper errors
//TODO maybe combine with ValidatorTimelock
contract MultisigCommiter is ValidatorTimelock, EIP712Upgradeable {
	/// @dev EIP-712 TypeHash for commitBatchesMultisig
    bytes32 internal constant COMMIT_BATCHES_MULTISIG_TYPEHASH =
        keccak256("CommitBatchesMultisig(address chainAddress, uint256 processBatchFrom, uint256 processBatchTo, bytes batchData)");

	bytes32 internal constant COMMIT_VERIFIER_ROLE = keccak256("COMMIT_VERIFIER_ROLE");

	mapping(address chainAddress => uint256 signingThreshold) internal signingThreshold;

	constructor(address _bridgehubAddr) ValidatorTimelock(_bridgehubAddr) {}

	//TODO __EIP712_init

    function commitBatchesSharedBridge(
		address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _batchData
	) external override {
		require(signingThreshold[_chainAddress] == 0, "Chain requires verifiers signatures for commit");
		_recordBatchCommitment(_chainAddress, _processBatchFrom, _processBatchTo);
        _propagateToZKChain(_chainAddress);
	}

	function commitBatchesMultisig(
        address chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _batchData,
		address[] calldata signers,
		bytes[] calldata signatures
    ) external onlyRole(chainAddress, COMMITTER_ROLE) {
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(COMMIT_BATCHES_MULTISIG_TYPEHASH, chainAddress, _processBatchFrom, _processBatchTo, _batchData)));

		_checkSignatures(chainAddress, signers, signatures, digest);

		_recordBatchCommitment(chainAddress, _processBatchFrom, _processBatchTo);
		// we cannot use _propagateToZKChain here, becouse function signature is altered
		IExecutor(chainAddress).commitBatchesSharedBridge(chainAddress, _processBatchFrom, _processBatchTo, _batchData);
    }

	function _checkSignatures(address chainAddress, address[] calldata signers, bytes[] calldata signatures, bytes32 digest) internal view {
		require(signers.length == signatures.length, "Mismatching signatures length");
		require(signers.length >= signingThreshold[chainAddress], "Not enough signers");

		// signers must be sorted in order to cheaply validate they are not duplicated
		address previousSigner = address(0);
		for (uint256 i = 0; i < signers.length; i++) {
			require(signers[i] > previousSigner, "Signers must be sorted");
			require(hasRole(chainAddress, COMMIT_VERIFIER_ROLE, signers[i]), "Invalid signature");
			require(SignatureCheckerUpgradeable.isValidSignatureNow(signers[i], digest, signatures[i]), "Invalid signature");
			previousSigner = signers[i];
		}
	}
}