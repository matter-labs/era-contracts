// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

/**
 * @title Interface of the manager contract for modules
 * @author https://getclave.io
 */
interface IModuleManager {
    /**
     * @notice Event emitted when a module is added
     * @param module address - Address of the added module
     */
    event AddModule(address indexed module);

    /**
     * @notice Event emitted when a module is removed
     * @param module address - Address of the removed module
     */
    event RemoveModule(address indexed module);

    /**
     * @notice Add a module to the list of modules and call it's init function
     * @dev Can only be called by self or a module
     * @param moduleAndData bytes calldata - Address of the module and data to initialize it with
     */
    function addModule(bytes calldata moduleAndData) external;

    /**
     * @notice Remove a module from the list of modules and call it's disable function
     * @dev Can only be called by self or a module
     * @param module address - Address of the module to remove
     */
    function removeModule(address module) external;

    /**
     * @notice Allow modules to execute arbitrary calls on behalf of the account
     * @dev Can only be called by a module
     * @param to address - Address to call
     * @param value uint256 - Eth to send with call
     * @param data bytes memory - Data to make the call with
     */
    function executeFromModule(
        address to,
        uint256 value,
        bytes memory data
    ) external;

    /**
     * @notice Check if an address is in the list of modules
     * @param addr address - Address to check
     * @return bool - True if the address is a module, false otherwise
     */
    function isModule(address addr) external returns (bool);

    /**
     * @notice Get the list of modules
     * @return moduleList address[] memory - List of modules
     */
    function listModules() external view returns (address[] memory moduleList);
}
