// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

/**
 * @title Manager contract for validators
 * @author https://getclave.io
 */
interface IValidatorManager {
    /**
     * @notice Event emitted when a r1 validator is added
     * @param validator address - Address of the added r1 validator
     */
    event R1AddValidator(address indexed validator);

    /**
     * @notice Event emitted when a k1 validator is added
     * @param validator address - Address of the added k1 validator
     */
    event K1AddValidator(address indexed validator);

    /**
     * @notice Event emitted when a r1 validator is removed
     * @param validator address - Address of the removed r1 validator
     */
    event R1RemoveValidator(address indexed validator);

    /**
     * @notice Event emitted when a k1 validator is removed
     * @param validator address - Address of the removed k1 validator
     */
    event K1RemoveValidator(address indexed validator);

    /**
     * @notice Adds a validator to the list of r1 validators
     * @dev Can only be called by self or a whitelisted module
     * @param validator address - Address of the r1 validator to add
     */
    function r1AddValidator(address validator) external;

    /**
     * @notice Adds a validator to the list of k1 validators
     * @dev Can only be called by self or a whitelisted module
     * @param validator address - Address of the k1 validator to add
     */
    function k1AddValidator(address validator) external;

    /**
     * @notice Removes a validator from the list of r1 validators
     * @dev Can only be called by self or a whitelisted module
     * @dev Can not remove the last validator
     * @param validator address - Address of the validator to remove
     */
    function r1RemoveValidator(address validator) external;

    /**
     * @notice Removes a validator from the list of k1 validators
     * @dev Can only be called by self or a whitelisted module
     * @param validator address - Address of the validator to remove
     */
    function k1RemoveValidator(address validator) external;

    /**
     * @notice Checks if an address is in the r1 validator list
     * @param validator address -Address of the validator to check
     * @return True if the address is a validator, false otherwise
     */
    function r1IsValidator(address validator) external view returns (bool);

    /**
     * @notice Checks if an address is in the k1 validator list
     * @param validator address - Address of the validator to check
     * @return True if the address is a validator, false otherwise
     */
    function k1IsValidator(address validator) external view returns (bool);

    /**
     * @notice Returns the list of r1 validators
     * @return validatorList address[] memory - Array of r1 validator addresses
     */
    function r1ListValidators()
        external
        view
        returns (address[] memory validatorList);

    /**
     * @notice Returns the list of k1 validators
     * @return validatorList address[] memory - Array of k1 validator addresses
     */
    function k1ListValidators()
        external
        view
        returns (address[] memory validatorList);
}
