// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

/**
 * @title Interface of the manager contract for owners
 * @author https://getclave.io
 */
interface IOwnerManager {
    /**
     * @notice Event emitted when a r1 owner is added
     * @param pubKey bytes - r1 owner that has been added
     */
    event R1AddOwner(bytes pubKey);

    /**
     * @notice Event emitted when a k1 owner is added
     * @param addr address - k1 owner that has been added
     */
    event K1AddOwner(address indexed addr);

    /**
     * @notice Event emitted when a r1 owner is removed
     * @param pubKey bytes - r1 owner that has been removed
     */
    event R1RemoveOwner(bytes pubKey);

    /**
     * @notice Event emitted when a k1 owner is removed
     * @param addr address - k1 owner that has been removed
     */
    event K1RemoveOwner(address indexed addr);

    /**
     * @notice Event emitted when all owners are cleared
     */
    event ResetOwners();

    /**
     * @notice Adds a r1 owner to the list of r1 owners
     * @dev Can only be called by self or a whitelisted module
     * @dev Public Key length must be 64 bytes
     * @param pubKey bytes calldata - Public key to add to the list of r1 owners
     */
    function r1AddOwner(bytes calldata pubKey) external;

    /**
     * @notice Adds a k1 owner to the list of k1 owners
     * @dev Can only be called by self or a whitelisted module
     * @dev Address can not be the zero address
     * @param addr address - Address to add to the list of k1 owners
     */
    function k1AddOwner(address addr) external;

    /**
     * @notice Removes a r1 owner from the list of r1 owners
     * @dev Can only be called by self or a whitelisted module
     * @dev Can not remove the last r1 owner
     * @param pubKey bytes calldata - Public key to remove from the list of r1 owners
     */
    function r1RemoveOwner(bytes calldata pubKey) external;

    /**
     * @notice Removes a k1 owner from the list of k1 owners
     * @dev Can only be called by self or a whitelisted module
     * @param addr address - Address to remove from the list of k1 owners
     */
    function k1RemoveOwner(address addr) external;

    /**
     * @notice Clears both r1 owners and k1 owners and adds an r1 owner
     * @dev Can only be called by self or a whitelisted module
     * @dev Public Key length must be 64 bytes
     * @param pubKey bytes calldata - new r1 owner to add
     */
    function resetOwners(bytes calldata pubKey) external;

    /**
     * @notice Checks if a public key is in the list of r1 owners
     * @param pubKey bytes calldata - Public key to check
     * @return bool - True if the public key is in the list, false otherwise
     */
    function r1IsOwner(bytes calldata pubKey) external view returns (bool);

    /**
     * @notice Checks if an address is in the list of k1 owners
     * @param addr address - Address to check
     * @return bool - True if the address is in the list, false otherwise
     */
    function k1IsOwner(address addr) external view returns (bool);

    /**
     * @notice Returns the list of r1 owners
     * @return r1OwnerList bytes[] memory - Array of r1 owner public keys
     */
    function r1ListOwners() external view returns (bytes[] memory r1OwnerList);

    /**
     * @notice Returns the list of k1 owners
     * @return k1OwnerList address[] memory - Array of k1 owner addresses
     */
    function k1ListOwners()
        external
        view
        returns (address[] memory k1OwnerList);
}
