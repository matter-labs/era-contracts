// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../interfaces/IGovernance.sol";
import "../../common/libraries/L2ContractHelper.sol";
import {L2_TX_MAX_GAS_LIMIT} from "../Config.sol";
import "./Base.sol";

/// @title Governance Contract controls access rights for contract management.
/// @author Matter Labs
contract GovernanceFacet is Base, IGovernance {
    string public constant override getName = "GovernanceFacet";

    /// @notice Starts the transfer of governor rights. Only the current governor can propose a new pending one.
    /// @notice New governor can accept governor rights by calling `acceptGovernor` function.
    /// @param _newPendingGovernor Address of the new governor
    function setPendingGovernor(address _newPendingGovernor) external onlyGovernor {
        // Save previous value into the stack to put it into the event later
        address oldPendingGovernor = s.pendingGovernor;
        // Change pending governor
        s.pendingGovernor = _newPendingGovernor;
        emit NewPendingGovernor(oldPendingGovernor, _newPendingGovernor);
    }

    /// @notice Accepts transfer of admin rights. Only pending governor can accept the role.
    function acceptGovernor() external {
        address pendingGovernor = s.pendingGovernor;
        require(msg.sender == pendingGovernor, "n4"); // Only proposed by current governor address can claim the governor rights

        address previousGovernor = s.governor;
        s.governor = pendingGovernor;
        delete s.pendingGovernor;

        emit NewPendingGovernor(pendingGovernor, address(0));
        emit NewGovernor(previousGovernor, pendingGovernor);
    }

    /// @notice Change validator status (active or not active)
    /// @param _validator Validator address
    /// @param _active Active flag
    function setValidator(address _validator, bool _active) external onlyGovernor {
        s.validators[_validator] = _active;
        emit ValidatorStatusUpdate(_validator, _active);
    }

    /// @notice Change zk porter availability
    /// @param _zkPorterIsAvailable The availability of zk porter shard
    function setPorterAvailability(bool _zkPorterIsAvailable) external onlyGovernor {
        // Change the porter availability
        s.zkPorterIsAvailable = _zkPorterIsAvailable;
        emit IsPorterAvailableStatusUpdate(_zkPorterIsAvailable);
    }

    /// @notice Change the max L2 gas limit for L1 -> L2 transactions
    /// @param _newPriorityTxMaxGasLimit The maximum number of L2 gas that a user can request for L1 -> L2 transactions
    function setPriorityTxMaxGasLimit(uint256 _newPriorityTxMaxGasLimit) external onlyGovernor {
        require(_newPriorityTxMaxGasLimit <= L2_TX_MAX_GAS_LIMIT, "n5");

        uint256 oldPriorityTxMaxGasLimit = s.priorityTxMaxGasLimit;
        s.priorityTxMaxGasLimit = _newPriorityTxMaxGasLimit;
        emit NewPriorityTxMaxGasLimit(oldPriorityTxMaxGasLimit, _newPriorityTxMaxGasLimit);
    }
}
