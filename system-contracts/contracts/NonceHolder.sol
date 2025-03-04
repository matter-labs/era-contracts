// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {INonceHolder} from "./interfaces/INonceHolder.sol";
import {SystemContractBase} from "./abstract/SystemContractBase.sol";
import {DEPLOYER_SYSTEM_CONTRACT} from "./Constants.sol";
import {NonceIncreaseError, ValueMismatch, NonceAlreadyUsed, NonceNotUsed, Unauthorized, InvalidNonceKey} from "./SystemContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice A contract used for managing nonces for accounts. Together with bootloader,
 * this contract ensures that the pair (sender, nonce) is always unique, ensuring
 * unique transaction hashes.
 * @dev The account allows for both ascending growth in nonces and mapping nonces to specific
 * stored values in them.
 * The users can mark a range of nonces by increasing the `minNonce`. This way all the nonces
 * less than `minNonce` will become used. The other way to mark a certain 256-bit key as nonce is to set
 * some value under it in this contract.
 * @dev Apart from transaction nonces, this contract also stores the deployment nonce for accounts, that
 * will be used for address derivation using CREATE. For the economy of space, this nonce is stored tightly
 * packed with the `minNonce`.
 * @dev The behavior of some of the methods depends on the nonce ordering of the account. Nonce ordering is a mere suggestion and all the checks that are present
 * here serve more as a help to users to prevent from doing mistakes, rather than any invariants.
 */
contract NonceHolder is INonceHolder, SystemContractBase {
    uint256 private constant DEPLOY_NONCE_MULTIPLIER = 2 ** 128;
    /// The minNonce can be increased by 2^32 at a time to prevent it from
    /// overflowing beyond 2**128.
    uint256 private constant MAXIMAL_MIN_NONCE_INCREMENT = 2 ** 32;

    /// RawNonces for accounts are stored in format
    /// minNonce + 2^128 * deploymentNonce, where deploymentNonce
    /// is the nonce used for deploying smart contracts,
    /// and minNonce is the first unused nonce with nonceKey (upper 192 bits) zero.
    mapping(uint256 account => uint256 packedMinAndDeploymentNonce) internal rawNonces;

    /// Mapping of values under nonces for accounts.
    /// The main key of the mapping is the 256-bit address of the account, while the
    /// inner mapping is a mapping from a nonce to the value stored there.
    /// DEPRECATED: users can no longer set values under nonces.
    mapping(uint256 account => mapping(uint256 nonce => uint256 storedValue)) internal __DEPRECATED_nonceValues;

    /// This mapping tracks minNonce for non-zero nonce keys.
    mapping(uint256 account => mapping(uint192 nonceKey => uint64 nonceValue)) internal keyedNonces;

    /// @notice Returns the current minimal nonce for account.
    /// @param _address The account to return the minimal nonce for
    /// @return The current minimal nonce for this account.
    function getMinNonce(address _address) public view returns (uint256) {
        uint256 addressAsKey = uint256(uint160(_address));
        (, uint256 minNonce) = _splitRawNonce(rawNonces[addressAsKey]);

        return minNonce;
    }

    /// @notice Returns the raw version of the current minimal nonce
    /// @dev It is equal to minNonce + 2^128 * deployment nonce.
    /// @param _address The account to return the raw nonce for
    /// @return The raw nonce for this account.
    function getRawNonce(address _address) public view returns (uint256) {
        uint256 addressAsKey = uint256(uint160(_address));
        return rawNonces[addressAsKey];
    }

    /// @notice Increases the minimal nonce for the msg.sender and returns the previous one.
    /// @param _value The number by which to increase the minimal nonce for msg.sender.
    /// @return oldMinNonce The value of the minimal nonce for msg.sender before the increase.
    function increaseMinNonce(uint256 _value) public onlySystemCall returns (uint256 oldMinNonce) {
        if (_value > MAXIMAL_MIN_NONCE_INCREMENT) {
            revert NonceIncreaseError(MAXIMAL_MIN_NONCE_INCREMENT, _value);
        }

        uint256 addressAsKey = uint256(uint160(msg.sender));
        uint256 oldRawNonce = rawNonces[addressAsKey];

        unchecked {
            rawNonces[addressAsKey] = (oldRawNonce + _value);
        }

        (, oldMinNonce) = _splitRawNonce(oldRawNonce);
    }

    function _splitKeyedNonce(uint256 _nonce) private pure returns (uint192 nonceKey, uint64 nonceValue) {
        nonceKey = uint192(_nonce >> 64);
        nonceValue = uint64(_nonce);
    }

    /// @notice A convenience method to increment the minimal nonce if it is equal
    /// to the `_expectedNonce`.
    /// @dev This function only increments minMince for nonces with nonceKey == 0.
    /// AAs that try to use this method with a keyed nonce will revert.
    /// For keyed nonces, `incrementMinNonceIfEqualsKeyed` should be used.
    /// This is to prevent DefaultAccount and other deployed AAs from
    /// unintentionally allowing keyed nonces to be used.
    /// @param _expectedNonce The expected minimal nonce for the account.
    function incrementMinNonceIfEquals(uint256 _expectedNonce) external onlySystemCall {
        (uint192 nonceKey, ) = _splitKeyedNonce(_expectedNonce);
        if (nonceKey != 0) {
            revert InvalidNonceKey(nonceKey);
        }

        uint256 addressAsKey = uint256(uint160(msg.sender));
        uint256 oldRawNonce = rawNonces[addressAsKey];

        (, uint256 oldMinNonce) = _splitRawNonce(oldRawNonce);
        if (oldMinNonce != _expectedNonce) {
            revert ValueMismatch(_expectedNonce, oldMinNonce);
        }

        unchecked {
            rawNonces[addressAsKey] = oldRawNonce + 1;
        }
    }

    /// @notice A convenience method to increment the minimal nonce if it is equal
    /// to the `_expectedNonce`. This is a keyed counterpart to `incrementMinNonceIfEquals`.
    /// Reverts for nonces with nonceKey == 0.
    /// @param _expectedNonce The expected minimal nonce for the account.
    function incrementMinNonceIfEqualsKeyed(uint256 _expectedNonce) external onlySystemCall {
        (uint192 nonceKey, uint64 nonceValue) = _splitKeyedNonce(_expectedNonce);
        if (nonceKey == 0) {
            revert InvalidNonceKey(nonceKey);
        }

        uint256 addressAsKey = uint256(uint160(msg.sender));
        uint64 oldNonceValue = keyedNonces[addressAsKey][nonceKey];
        if (oldNonceValue != nonceValue) {
            revert ValueMismatch(nonceValue, oldNonceValue);
        }

        unchecked {
            keyedNonces[addressAsKey][nonceKey] = nonceValue + 1;
        }
    }

    /// @notice Returns the deployment nonce for the accounts used for CREATE opcode.
    /// @param _address The address to return the deploy nonce of.
    /// @return deploymentNonce The deployment nonce of the account.
    function getDeploymentNonce(address _address) external view returns (uint256 deploymentNonce) {
        uint256 addressAsKey = uint256(uint160(_address));
        (deploymentNonce, ) = _splitRawNonce(rawNonces[addressAsKey]);

        return deploymentNonce;
    }

    /// @notice Increments the deployment nonce for the account and returns the previous one.
    /// @param _address The address of the account which to return the deploy nonce for.
    /// @return prevDeploymentNonce The deployment nonce at the time this function is called.
    function incrementDeploymentNonce(address _address) external returns (uint256 prevDeploymentNonce) {
        if (msg.sender != address(DEPLOYER_SYSTEM_CONTRACT)) {
            revert Unauthorized(msg.sender);
        }
        uint256 addressAsKey = uint256(uint160(_address));
        uint256 oldRawNonce = rawNonces[addressAsKey];

        unchecked {
            rawNonces[addressAsKey] = (oldRawNonce + DEPLOY_NONCE_MULTIPLIER);
        }

        (prevDeploymentNonce, ) = _splitRawNonce(oldRawNonce);
    }

    /// @notice A method that checks whether the nonce has been used before.
    /// @param _address The address the nonce of which is being checked.
    /// @param _nonce The nonce value which is checked.
    /// @return `true` if the nonce has been used, `false` otherwise.
    function isNonceUsed(address _address, uint256 _nonce) public view returns (bool) {
        uint256 addressAsKey = uint256(uint160(_address));
        (uint192 nonceKey, uint64 nonceValue) = _splitKeyedNonce(_nonce);
        // We keep the `nonceValues` check here, until it is confirmed that this mapping has never been used by anyone.
        return _nonce < getMinNonce(_address) || nonceValue < keyedNonces[addressAsKey][nonceKey] || __DEPRECATED_nonceValues[addressAsKey][_nonce] > 0;
    }

    /// @notice Checks and reverts based on whether the nonce is used (not used).
    /// @param _address The address the nonce of which is being checked.
    /// @param _key The nonce value which is tested.
    /// @param _shouldBeUsed The flag for the method. If `true`, the method checks that whether this nonce
    /// is marked as used and reverts if this is not the case. If `false`, this method will check that the nonce
    /// has *not* been used yet, and revert otherwise.
    /// @dev This method should be used by the bootloader.
    function validateNonceUsage(address _address, uint256 _key, bool _shouldBeUsed) external view {
        bool isUsed = isNonceUsed(_address, _key);

        if (isUsed && !_shouldBeUsed) {
            revert NonceAlreadyUsed(_address, _key);
        } else if (!isUsed && _shouldBeUsed) {
            revert NonceNotUsed(_address, _key);
        }
    }

    /// @notice Splits the raw nonce value into the deployment nonce and the minimal nonce.
    /// @param _rawMinNonce The value of the raw minimal nonce (equal to minNonce + deploymentNonce* 2**128).
    /// @return deploymentNonce and minNonce.
    function _splitRawNonce(uint256 _rawMinNonce) internal pure returns (uint256 deploymentNonce, uint256 minNonce) {
        deploymentNonce = _rawMinNonce / DEPLOY_NONCE_MULTIPLIER;
        minNonce = _rawMinNonce % DEPLOY_NONCE_MULTIPLIER;
    }
}
