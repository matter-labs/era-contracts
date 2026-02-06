// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/cryptography/EIP712Upgradeable.sol";
import {SignatureCheckerUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/cryptography/SignatureCheckerUpgradeable.sol";
import {EnumerableSetUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/structs/EnumerableSetUpgradeable.sol";
import {SignersNotSorted, SignerNotAuthorized, SignatureNotValid, ChainRequiresValidatorsSignaturesForCommit, SignaturesLengthMismatch, NotEnoughSigners, InvalidThreshold} from "../../common/L1ContractErrors.sol";
import {ICommitter} from "../chain-interfaces/ICommitter.sol";
import {ValidatorTimelock} from "./ValidatorTimelock.sol";
import {IValidatorTimelock} from "./interfaces/IValidatorTimelock.sol";
import {IMultisigCommitter} from "./interfaces/IMultisigCommitter.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Extended ValidatorTimelock with commit function (optionally) locked
/// behind providing extra signatures from validators. By default a shared signing
/// set is used. Custom signing set with custom threshold can be elected by
/// chainAdmin instead if allowed by owner.
/// @dev The purpose of this contract is to require multiple validators check each
/// commit operation before a sequencer can perform it. Validators cannot start
/// commit operations. Only Committer can call commitBatchesMultisig, but requires
/// providing extra signatures argument
/// @dev Expected to be deployed as a TransparentUpgradeableProxy.
contract MultisigCommitter is IMultisigCommitter, ValidatorTimelock, EIP712Upgradeable {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    /// @dev EIP-712 TypeHash for commitBatchesMultisig
    bytes32 internal constant COMMIT_BATCHES_MULTISIG_TYPEHASH =
        keccak256(
            "CommitBatchesMultisig(address chainAddress,uint256 processBatchFrom,uint256 processBatchTo,bytes batchData)"
        );

    /// @dev The per chain validator role, only applies if useCustomValidators is set
    bytes32 public constant override COMMIT_VALIDATOR_ROLE = keccak256("COMMIT_VALIDATOR_ROLE");

    /// @dev The list of shared validators, used if useCustomValidators is false for a chain and
    /// apply to all chains by default.
    EnumerableSetUpgradeable.AddressSet private sharedValidators;

    /// @inheritdoc IMultisigCommitter
    uint64 public override sharedSigningThreshold;

    /// @dev Per chain configuration
    mapping(address chainAddress => ChainConfig) public chainConfig;

    constructor(address _bridgehubAddr) ValidatorTimelock(_bridgehubAddr) {
        _disableInitializers();
    }

    /// @notice The initializer for the proxy of the contract. For compatibility with the mainnet deployment
    /// we initialize to the second version.
    /// @param _initialOwner The initial owner address
    /// @param _initialExecutionDelay The initial execution delay
    function initializeV2(address _initialOwner, uint32 _initialExecutionDelay) external reinitializer(2) {
        _validatorTimelockInit(_initialOwner, _initialExecutionDelay);
        __EIP712_init("MultisigCommitter", "1");
    }

    /// @notice Reinitializer for version 2. We can not directly reuse the ValidatorTimelock's initializer, because
    /// it has been already used in the proxy deployment.
    /// @dev Should be used for production when upgrading the validator timelock to the new version.
    function reinitializeV2() external reinitializer(2) {
        __EIP712_init("MultisigCommitter", "1");
    }

    /// @inheritdoc IValidatorTimelock
    function commitBatchesSharedBridge(
        address _chainAddress,
        uint256 _processBatchFrom,
        uint256 _processBatchTo,
        bytes calldata _batchData
    ) public override(ValidatorTimelock, IValidatorTimelock) {
        if (getSigningThreshold(_chainAddress) != 0) revert ChainRequiresValidatorsSignaturesForCommit();
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
    ) external override onlyRole(chainAddress, COMMITTER_ROLE) {
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    COMMIT_BATCHES_MULTISIG_TYPEHASH,
                    chainAddress,
                    processBatchFrom,
                    processBatchTo,
                    keccak256(batchData)
                )
            )
        );
        _checkSignatures(chainAddress, signers, signatures, digest);
        // signatures validated, follow normal commitBatchesSharedBridge flow
        _recordBatchCommitment(chainAddress, processBatchFrom, processBatchTo);
        // we cannot use _propagateToZKChain here, because function signature is altered
        ICommitter(chainAddress).commitBatchesSharedBridge(chainAddress, processBatchFrom, processBatchTo, batchData);
    }

    /// @inheritdoc IMultisigCommitter
    function getSigningThreshold(address chainAddress) public view override returns (uint64) {
        ChainConfig memory config = chainConfig[chainAddress];
        if (config.useCustomValidators) return config.signingThreshold;
        else return sharedSigningThreshold;
    }

    /// @inheritdoc IMultisigCommitter
    function isCustomSigningSetActive(address chainAddress) external view override returns (bool) {
        return chainConfig[chainAddress].useCustomValidators;
    }

    /// @inheritdoc IMultisigCommitter
    function isValidator(address chainAddress, address validator) external view override returns (bool) {
        if (chainConfig[chainAddress].useCustomValidators) {
            return hasRole(chainAddress, COMMIT_VALIDATOR_ROLE, validator);
        } else {
            return sharedValidators.contains(validator);
        }
    }

    /// @inheritdoc IMultisigCommitter
    function getValidatorsCount(address chainAddress) external view override returns (uint256) {
        if (chainConfig[chainAddress].useCustomValidators) {
            return getRoleMemberCount(chainAddress, COMMIT_VALIDATOR_ROLE);
        } else {
            return sharedValidators.length();
        }
    }

    /// @inheritdoc IMultisigCommitter
    function getValidatorsMember(address chainAddress, uint256 index) external view override returns (address) {
        if (chainConfig[chainAddress].useCustomValidators) {
            return getRoleMember(chainAddress, COMMIT_VALIDATOR_ROLE, index);
        } else {
            return sharedValidators.at(index);
        }
    }

    /// @inheritdoc IMultisigCommitter
    function setCustomSigningThreshold(
        address chainAddress,
        uint64 _signingThreshold
    ) external override onlyRole(chainAddress, getRoleAdmin(chainAddress, COMMIT_VALIDATOR_ROLE)) {
        if (_signingThreshold > getRoleMemberCount(chainAddress, COMMIT_VALIDATOR_ROLE))
            revert InvalidThreshold(getRoleMemberCount(chainAddress, COMMIT_VALIDATOR_ROLE), _signingThreshold);
        chainConfig[chainAddress].signingThreshold = _signingThreshold;
        emit NewCustomSigningThreshold(chainAddress, _signingThreshold);
    }

    /// @inheritdoc IMultisigCommitter
    function useSharedSigningSet(
        address chainAddress
    ) external override onlyRole(chainAddress, getRoleAdmin(chainAddress, COMMIT_VALIDATOR_ROLE)) {
        chainConfig[chainAddress].useCustomValidators = false;
        emit UseCustomValidators(chainAddress, false);
    }

    /// @inheritdoc IMultisigCommitter
    function useCustomSigningSet(address chainAddress) external override onlyOwner {
        chainConfig[chainAddress].useCustomValidators = true;
        emit UseCustomValidators(chainAddress, true);
    }

    /// @inheritdoc IMultisigCommitter
    function setSharedSigningThreshold(uint64 _signingThreshold) external override onlyOwner {
        if (_signingThreshold > sharedValidators.length())
            revert InvalidThreshold(sharedValidators.length(), _signingThreshold);
        sharedSigningThreshold = _signingThreshold;
        emit NewSharedSigningThreshold(_signingThreshold);
    }

    /// @inheritdoc IMultisigCommitter
    function addSharedValidator(address validator) external override onlyOwner {
        if (!sharedValidators.contains(validator)) {
            // slither-disable-next-line unused-return
            sharedValidators.add(validator);
            emit SharedValidatorAdded(validator);
        }
        // no-op if validator is already in the set
    }

    /// @inheritdoc IMultisigCommitter
    function removeSharedValidator(address validator) external override onlyOwner {
        if (sharedValidators.contains(validator)) {
            // slither-disable-next-line unused-return
            sharedValidators.remove(validator);
            emit SharedValidatorRemoved(validator);
        }
        // no-op if validator is not in the set
    }

    /// @inheritdoc IMultisigCommitter
    function sharedValidatorsCount() external view override returns (uint256) {
        return sharedValidators.length();
    }

    /// @inheritdoc IMultisigCommitter
    function sharedValidatorsMember(uint256 index) external view override returns (address) {
        return sharedValidators.at(index);
    }

    /// @inheritdoc IMultisigCommitter
    function isSharedValidator(address validator) external view override returns (bool) {
        return sharedValidators.contains(validator);
    }

    function _checkSignatures(
        address chainAddress,
        address[] calldata signers,
        bytes[] calldata signatures,
        bytes32 digest
    ) internal view {
        uint256 providedSigners = signers.length;
        if (providedSigners != signatures.length) revert SignaturesLengthMismatch(providedSigners, signatures.length);

        ChainConfig memory config = chainConfig[chainAddress];
        // splitting the logic here instead of using the getter function optimizes storage access
        if (config.useCustomValidators) {
            if (providedSigners < config.signingThreshold) {
                revert NotEnoughSigners(providedSigners, config.signingThreshold);
            }
        } else {
            if (providedSigners < sharedSigningThreshold) {
                revert NotEnoughSigners(providedSigners, sharedSigningThreshold);
            }
        }

        // signers must be sorted in order to cheaply validate they are not duplicated
        address previousSigner = address(0);
        for (uint256 i = 0; i < providedSigners; ++i) {
            if (signers[i] <= previousSigner) {
                revert SignersNotSorted();
            }
            // checking here instead of using the getter function optimizes storage access
            if (config.useCustomValidators) {
                if (!hasRole(chainAddress, COMMIT_VALIDATOR_ROLE, signers[i])) {
                    revert SignerNotAuthorized(signers[i]);
                }
            } else {
                if (!sharedValidators.contains(signers[i])) {
                    revert SignerNotAuthorized(signers[i]);
                }
            }
            if (!SignatureCheckerUpgradeable.isValidSignatureNow(signers[i], digest, signatures[i])) {
                revert SignatureNotValid(signers[i]);
            }
            previousSigner = signers[i];
        }
    }
}
