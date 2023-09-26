// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

interface IGovernance {
    /// @dev This enumeration includes the following states:
    /// @param Unset Default state, indicating the operation has not been set.
    /// @param Waiting The operation is scheduled but not yet ready to be executed.
    /// @param Ready The operation is ready to be executed.
    /// @param Done The operation has been successfully executed.
    enum OperationState {
        Unset,
        Waiting,
        Ready,
        Done
    }

    /// @dev Represents a call to be made during an operation.
    /// @param target The address to which the call will be made.
    /// @param value The amount of Ether (in wei) to be sent along with the call.
    /// @param data The call data to be executed on the `target` address.
    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    /// @dev Defines the structure of an operation that Governance executes.
    /// @param calls An array of `Call` structs, each representing a call to be made during the operation.
    /// @param predecessor The hash of the predecessor operation, that should be executed before this operation.
    /// @param salt A bytes32 value used for creating unique operation hashes.
    struct Operation {
        Call[] calls;
        bytes32 predecessor;
        bytes32 salt;
    }

    function isOperation(bytes32 _id) external view returns (bool);

    function isOperationPending(bytes32 _id) external view returns (bool);

    function isOperationReady(bytes32 _id) external view returns (bool);

    function isOperationDone(bytes32 _id) external view returns (bool);

    function getOperationState(bytes32 _id) external view returns (OperationState);

    function scheduleTransparent(Operation calldata _operation, uint256 _delay) external;

    function scheduleShadow(bytes32 _id, uint256 _delay) external;

    function cancel(bytes32 _id) external;
    
    function execute(Operation calldata _operation) external;

    function executeInstant(Operation calldata _operation) external;

    function hashOperation(Operation calldata _operation) external pure returns (bytes32);

    function updateDelay(uint256 _newDelay) external;

    function updateSecurityCouncil(address _newSecurityCouncil) external;
}
