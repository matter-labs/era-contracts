// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IGovernance} from "./IGovernance.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Contract design is inspired by OpenZeppelin TimelockController and in-house Diamond Proxy upgrade mechanism.
/// @notice This contract manages operations (calls with preconditions) for governance tasks.
/// The contract allows for operations to be scheduled, executed, and canceled with
/// appropriate permissions and delays. It is used for managing and coordinating upgrades
/// and changes in all zkSync hyperchain governed contracts.
///
/// Operations can be proposed as either fully transparent upgrades with on-chain data,
/// or "shadow" upgrades where upgrade data is not published on-chain before execution. Proposed operations
/// are subject to a delay before they can be executed, but they can be executed instantly
/// with the security council’s permission.
contract Governance is IGovernance, Ownable2Step {
    /// @notice A constant representing the timestamp for completed operations.
    uint256 internal constant EXECUTED_PROPOSAL_TIMESTAMP = uint256(1);

    /// @notice The address of the security council.
    /// @dev It is supposed to be multisig contract.
    address public securityCouncil;

    /// @notice A mapping to store timestamps when each operation will be ready for execution.
    /// @dev - 0 means the operation is not created.
    /// @dev - 1 (EXECUTED_PROPOSAL_TIMESTAMP) means the operation is already executed.
    /// @dev - any other value means timestamp in seconds when the operation will be ready for execution.
    mapping(bytes32 operationId => uint256 executionTimestamp) public timestamps;

    /// @notice The minimum delay in seconds for operations to be ready for execution.
    uint256 public minDelay;

    /// @notice Initializes the contract with the admin address, security council address, and minimum delay.
    /// @param _admin The address to be assigned as the admin of the contract.
    /// @param _securityCouncil The address to be assigned as the security council of the contract.
    /// @param _minDelay The initial minimum delay (in seconds) to be set for operations.
    constructor(address _admin, address _securityCouncil, uint256 _minDelay) {
        require(_admin != address(0), "Admin should be non zero address");

        _transferOwnership(_admin);

        securityCouncil = _securityCouncil;
        emit ChangeSecurityCouncil(address(0), _securityCouncil);

        minDelay = _minDelay;
        emit ChangeMinDelay(0, _minDelay);
    }

    /*//////////////////////////////////////////////////////////////
                            MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Checks that the message sender is contract itself.
    modifier onlySelf() {
        require(msg.sender == address(this), "Only governance contract itself is allowed to call this function");
        _;
    }

    /// @notice Checks that the message sender is an active security council.
    modifier onlySecurityCouncil() {
        require(msg.sender == securityCouncil, "Only security council is allowed to call this function");
        _;
    }

    /// @notice Checks that the message sender is an active owner or an active security council.
    modifier onlyOwnerOrSecurityCouncil() {
        require(
            msg.sender == owner() || msg.sender == securityCouncil,
            "Only the owner and security council are allowed to call this function"
        );
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            OPERATION GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns whether an id corresponds to a registered operation. This
    /// includes Waiting, Ready, and Done operations.
    function isOperation(bytes32 _id) public view returns (bool) {
        return getOperationState(_id) != OperationState.Unset;
    }

    /// @dev Returns whether an operation is pending or not. Note that a "pending" operation may also be "ready".
    function isOperationPending(bytes32 _id) public view returns (bool) {
        OperationState state = getOperationState(_id);
        return state == OperationState.Waiting || state == OperationState.Ready;
    }

    /// @dev Returns whether an operation is ready for execution. Note that a "ready" operation is also "pending".
    function isOperationReady(bytes32 _id) public view returns (bool) {
        return getOperationState(_id) == OperationState.Ready;
    }

    /// @dev Returns whether an operation is done or not.
    function isOperationDone(bytes32 _id) public view returns (bool) {
        return getOperationState(_id) == OperationState.Done;
    }

    /// @dev Returns operation state.
    function getOperationState(bytes32 _id) public view returns (OperationState) {
        uint256 timestamp = timestamps[_id];
        if (timestamp == 0) {
            return OperationState.Unset;
        } else if (timestamp == EXECUTED_PROPOSAL_TIMESTAMP) {
            return OperationState.Done;
        } else if (timestamp > block.timestamp) {
            return OperationState.Waiting;
        } else {
            return OperationState.Ready;
        }
    }

    /*//////////////////////////////////////////////////////////////
                            SCHEDULING CALLS
    //////////////////////////////////////////////////////////////*/

    /// @notice Propose a fully transparent upgrade, providing upgrade data on-chain.
    /// @notice The owner will be able to execute the proposal either:
    /// - With a `delay` timelock on its own.
    /// - With security council instantly.
    /// @dev Only the current owner can propose an upgrade.
    /// @param _operation The operation parameters will be executed with the upgrade.
    /// @param _delay The delay time (in seconds) after which the proposed upgrade can be executed by the owner.
    function scheduleTransparent(Operation calldata _operation, uint256 _delay) external onlyOwner {
        bytes32 id = hashOperation(_operation);
        _schedule(id, _delay);
        emit TransparentOperationScheduled(id, _delay, _operation);
    }

    /// @notice Propose "shadow" upgrade, upgrade data is not publishing on-chain.
    /// @notice The owner will be able to execute the proposal either:
    /// - With a `delay` timelock on its own.
    /// - With security council instantly.
    /// @dev Only the current owner can propose an upgrade.
    /// @param _id The operation hash (see `hashOperation` function)
    /// @param _delay The delay time (in seconds) after which the proposed upgrade may be executed by the owner.
    function scheduleShadow(bytes32 _id, uint256 _delay) external onlyOwner {
        _schedule(_id, _delay);
        emit ShadowOperationScheduled(_id, _delay);
    }

    /*//////////////////////////////////////////////////////////////
                            CANCELING CALLS
    //////////////////////////////////////////////////////////////*/

    /// @dev Cancel the scheduled operation.
    /// @dev Only owner can call this function.
    /// @param _id Proposal id value (see `hashOperation`)
    function cancel(bytes32 _id) external onlyOwner {
        require(isOperationPending(_id), "Operation must be pending");
        delete timestamps[_id];
        emit OperationCancelled(_id);
    }

    /*//////////////////////////////////////////////////////////////
                            EXECUTING CALLS
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes the scheduled operation after the delay passed.
    /// @dev Both the owner and security council may execute delayed operations.
    /// @param _operation The operation parameters will be executed with the upgrade.
    //  slither-disable-next-line reentrancy-eth
    function execute(Operation calldata _operation) external payable onlyOwnerOrSecurityCouncil {
        bytes32 id = hashOperation(_operation);
        // Check if the predecessor operation is completed.
        _checkPredecessorDone(_operation.predecessor);
        // Ensure that the operation is ready to proceed.
        require(isOperationReady(id), "Operation must be ready before execution");
        // Execute operation.
        // slither-disable-next-line reentrancy-eth
        _execute(_operation.calls);
        // Reconfirming that the operation is still ready after execution.
        // This is needed to avoid unexpected reentrancy attacks of re-executing the same operation.
        require(isOperationReady(id), "Operation must be ready after execution");
        // Set operation to be done
        timestamps[id] = EXECUTED_PROPOSAL_TIMESTAMP;
        emit OperationExecuted(id);
    }

    /// @notice Executes the scheduled operation with the security council instantly.
    /// @dev Only the security council may execute an operation instantly.
    /// @param _operation The operation parameters will be executed with the upgrade.
    //  slither-disable-next-line reentrancy-eth
    function executeInstant(Operation calldata _operation) external payable onlySecurityCouncil {
        bytes32 id = hashOperation(_operation);
        // Check if the predecessor operation is completed.
        _checkPredecessorDone(_operation.predecessor);
        // Ensure that the operation is in a pending state before proceeding.
        require(isOperationPending(id), "Operation must be pending before execution");
        // Execute operation.
        // slither-disable-next-line reentrancy-eth
        _execute(_operation.calls);
        // Reconfirming that the operation is still pending before execution.
        // This is needed to avoid unexpected reentrancy attacks of re-executing the same operation.
        require(isOperationPending(id), "Operation must be pending after execution");
        // Set operation to be done
        timestamps[id] = EXECUTED_PROPOSAL_TIMESTAMP;
        emit OperationExecuted(id);
    }

    /// @dev Returns the identifier of an operation.
    /// @param _operation The operation object to compute the identifier for.
    function hashOperation(Operation calldata _operation) public pure returns (bytes32) {
        return keccak256(abi.encode(_operation));
    }

    /*//////////////////////////////////////////////////////////////
                            HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Schedule an operation that is to become valid after a given delay.
    /// @param _id The operation hash (see `hashOperation` function)
    /// @param _delay The delay time (in seconds) after which the proposed upgrade can be executed by the owner.
    function _schedule(bytes32 _id, uint256 _delay) internal {
        require(!isOperation(_id), "Operation with this proposal id already exists");
        require(_delay >= minDelay, "Proposed delay is less than minimum delay");

        timestamps[_id] = block.timestamp + _delay;
    }

    /// @dev Execute an operation's calls.
    /// @param _calls The array of calls to be executed.
    function _execute(Call[] calldata _calls) internal {
        for (uint256 i = 0; i < _calls.length; ++i) {
            // slither-disable-next-line arbitrary-send-eth
            (bool success, bytes memory returnData) = _calls[i].target.call{value: _calls[i].value}(_calls[i].data);
            if (!success) {
                // Propagate an error if the call fails.
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }
    }

    /// @notice Verifies if the predecessor operation is completed.
    /// @param _predecessorId The hash of the operation that should be completed.
    /// @dev Doesn't check the operation to be complete if the input is zero.
    function _checkPredecessorDone(bytes32 _predecessorId) internal view {
        require(_predecessorId == bytes32(0) || isOperationDone(_predecessorId), "Predecessor operation not completed");
    }

    /*//////////////////////////////////////////////////////////////
                            SELF UPGRADES
    //////////////////////////////////////////////////////////////*/

    /// @dev Changes the minimum timelock duration for future operations.
    /// @param _newDelay The new minimum delay time (in seconds) for future operations.
    function updateDelay(uint256 _newDelay) external onlySelf {
        emit ChangeMinDelay(minDelay, _newDelay);
        minDelay = _newDelay;
    }

    /// @dev Updates the address of the security council.
    /// @param _newSecurityCouncil The address of the new security council.
    function updateSecurityCouncil(address _newSecurityCouncil) external onlySelf {
        emit ChangeSecurityCouncil(securityCouncil, _newSecurityCouncil);
        securityCouncil = _newSecurityCouncil;
    }

    /// @dev Contract might receive/hold ETH as part of the maintenance process.
    receive() external payable {}
}
