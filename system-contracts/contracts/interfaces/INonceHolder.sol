// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @dev Interface of the nonce holder contract -- a contract used by the system to ensure
 * that there is always a unique identifier for a transaction with a particular account (we call it nonce).
 * In other words, the pair of (address, nonce) should always be unique.
 * @dev Custom accounts should use methods of this contract to store nonces or other possible unique identifiers
 * for the transaction.
 */
interface INonceHolder {
    /// @notice Returns the current minimal nonce for account.
    /// @param _address The account to return the minimal nonce for
    /// @return The current minimal nonce for this account.
    function getMinNonce(address _address) external view returns (uint256);

    /// @notice Returns the current keyed nonce for account given its nonce key.
    /// @param _address The account to return the nonce for.
    /// @param _key The key of the nonce to return.
    /// @return The current keyed nonce with the given key for this account.
    /// Returns the full nonce (including the provided key), not just the nonce value.
    function getKeyedNonce(address _address, uint192 _key) external view returns (uint256);

    /// @notice Returns the raw version of the current minimal nonce
    /// @dev It is equal to minNonce + 2^128 * deployment nonce.
    /// @param _address The account to return the raw nonce for
    /// @return The raw nonce for this account.
    function getRawNonce(address _address) external view returns (uint256);

    /// @notice Increases the minimal nonce for the msg.sender and returns the previous one.
    /// @param _value The number by which to increase the minimal nonce for msg.sender.
    /// @return oldMinNonce The value of the minimal nonce for msg.sender before the increase.
    function increaseMinNonce(uint256 _value) external returns (uint256);

    /// @notice A convenience method to increment the minimal nonce if it is equal
    /// to the `_expectedNonce`.
    /// @dev This function only increments `minNonce` for nonces with nonceKey == 0.
    /// AAs that try to use this method with a keyed nonce will revert.
    /// For keyed nonces, `incrementMinNonceIfEqualsKeyed` should be used.
    /// This is to prevent DefaultAccount and other deployed AAs from
    /// unintentionally allowing keyed nonces to be used.
    /// @param _expectedNonce The expected minimal nonce for the account.
    function incrementMinNonceIfEquals(uint256 _expectedNonce) external;

    /// @notice A convenience method to increment the minimal nonce if it is equal
    /// to the `_expectedNonce`. This is a keyed counterpart to `incrementMinNonceIfEquals`.
    /// @dev Reverts for nonces with nonceKey == 0.
    /// @param _expectedNonce The expected minimal nonce for the account.
    function incrementMinNonceIfEqualsKeyed(uint256 _expectedNonce) external;

    /// @notice Returns the deployment nonce for the accounts used for CREATE opcode.
    /// @param _address The address to return the deploy nonce of.
    /// @return deploymentNonce The deployment nonce of the account.
    function getDeploymentNonce(address _address) external view returns (uint256);

    /// @notice Increments the deployment nonce for the account and returns the previous one.
    /// @param _address The address of the account which to return the deploy nonce for.
    /// @return prevDeploymentNonce The deployment nonce at the time this function is called.
    function incrementDeploymentNonce(address _address) external returns (uint256);

    /// @notice Checks and reverts based on whether the nonce is used (or not used).
    /// @param _address The address the nonce of which is being checked.
    /// @param _key The nonce value which is tested.
    /// @param _shouldBeUsed The flag for the method. If `true`, the method checks that whether this nonce
    /// is marked as used and reverts if this is not the case. If `false`, this method will check that the nonce
    /// has *not* been used yet, and revert otherwise.
    /// @dev This method should be used by the bootloader.
    function validateNonceUsage(address _address, uint256 _key, bool _shouldBeUsed) external view;

    /// @notice Returns whether a nonce has been used for an account.
    /// @param _address The address the nonce of which is being checked.
    /// @param _nonce The nonce value which is checked.
    /// @return `true` if the nonce has been used, `false` otherwise.
    function isNonceUsed(address _address, uint256 _nonce) external view returns (bool);
}
