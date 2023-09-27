// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../interfaces/IGovernance.sol";
import "../libraries/Diamond.sol";
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

        if (oldPendingGovernor != _newPendingGovernor) {
            // Change pending governor
            s.pendingGovernor = _newPendingGovernor;

            emit NewPendingGovernor(oldPendingGovernor, _newPendingGovernor);
        }
    }

    /// @notice Accepts transfer of admin rights. Only pending governor can accept the role.
    function acceptGovernor() external {
        address pendingGovernor = s.pendingGovernor;
        require(msg.sender == pendingGovernor, "n4"); // Only proposed by current governor address can claim the governor rights

        if (pendingGovernor != s.governor) {
            address previousGovernor = s.governor;
            s.governor = pendingGovernor;
            delete s.pendingGovernor;

            emit NewPendingGovernor(pendingGovernor, address(0));
            emit NewGovernor(previousGovernor, pendingGovernor);
        }
    }

    /// @notice Change validator status (active or not active)
    /// @param _validator Validator address
    /// @param _active Active flag
    function setValidator(address _validator, bool _active) external onlyGovernorOrItsOwner {
        if (s.validators[_validator] != _active) {
            s.validators[_validator] = _active;
            emit ValidatorStatusUpdate(_validator, _active);
        }
    }

    /// @notice Change zk porter availability
    /// @param _zkPorterIsAvailable The availability of zk porter shard
    function setPorterAvailability(bool _zkPorterIsAvailable) external onlyGovernor {
        if (s.zkPorterIsAvailable != _zkPorterIsAvailable) {
            // Change the porter availability
            s.zkPorterIsAvailable = _zkPorterIsAvailable;
            emit IsPorterAvailableStatusUpdate(_zkPorterIsAvailable);
        }
    }

    /// @notice Change the max L2 gas limit for L1 -> L2 transactions
    /// @param _newPriorityTxMaxGasLimit The maximum number of L2 gas that a user can request for L1 -> L2 transactions
    function setPriorityTxMaxGasLimit(uint256 _newPriorityTxMaxGasLimit) external onlyGovernor {
        uint256 oldPriorityTxMaxGasLimit = s.priorityTxMaxGasLimit;
        if (oldPriorityTxMaxGasLimit != _newPriorityTxMaxGasLimit) {
            s.priorityTxMaxGasLimit = _newPriorityTxMaxGasLimit;
            emit NewPriorityTxMaxGasLimit(oldPriorityTxMaxGasLimit, _newPriorityTxMaxGasLimit);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            UPGRADE EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a proposed governor upgrade
    /// @dev Only the current governor can execute the upgrade
    /// @param _diamondCut The diamond cut parameters to be executed
    function executeUpgrade(Diamond.DiamondCutData calldata _diamondCut) external onlyGovernor {
        Diamond.diamondCut(_diamondCut);
        emit ExecuteUpgrade(_diamondCut);
    }

    /*//////////////////////////////////////////////////////////////
                            CONTRACT FREEZING
    //////////////////////////////////////////////////////////////*/

    /// @notice Instantly pause the functionality of all freezable facets & their selectors
    /// @dev Only the governance mechanism may freeze Diamond Proxy
    function freezeDiamond() external onlyGovernor {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        require(!diamondStorage.isFrozen, "a9"); // diamond proxy is frozen already
        diamondStorage.isFrozen = true;

        emit Freeze();
    }

    /// @notice Unpause the functionality of all freezable facets & their selectors
    /// @dev Both the governor and its owner can unfreeze Diamond Proxy
    function unfreezeDiamond() external onlyGovernorOrItsOwner {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        require(diamondStorage.isFrozen, "a7"); // diamond proxy is not frozen
        diamondStorage.isFrozen = false;

        emit Unfreeze();
    }
}
