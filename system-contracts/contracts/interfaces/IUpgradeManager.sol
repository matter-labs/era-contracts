// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

/**
 * @title Interface of the upgrade manager contract
 * @author https://getclave.io
 */
interface IUpgradeManager {
    /**
     * @notice Event emitted when the contract is upgraded
     * @param oldImplementation address - Address of the old implementation contract
     * @param newImplementation address - Address of the new implementation contract
     */
    event Upgraded(
        address indexed oldImplementation,
        address indexed newImplementation
    );

    /**
     * @notice Upgrades the account contract to a new implementation
     * @dev Can only be called by self
     * @param newImplementation address - Address of the new implementation contract
     */
    function upgradeTo(address newImplementation) external;

    /**
     * @notice Returns the current implementation address
     * @return address - Address of the current implementation contract
     */
    function implementation() external view returns (address);
}
