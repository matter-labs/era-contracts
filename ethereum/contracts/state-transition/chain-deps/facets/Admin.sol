// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../chain-interfaces/IAdmin.sol";
import "../../../common/libraries/Diamond.sol";
import "../../../common/libraries/L2ContractHelper.sol";
import {L2_TX_MAX_GAS_LIMIT} from "../../../common/Config.sol";
import "./Base.sol";

/// @title Admin Contract controls access rights for contract management.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract AdminFacet is StateTransitionChainBase, IAdmin {
    string public constant override getName = "AdminFacet";

    /// @notice Starts the transfer of governor rights. Only the current governor can propose a new pending one.
    /// @notice New governor can accept governor rights by calling `acceptGovernor` function.
    /// @param _newPendingGovernor Address of the new governor
    function setPendingGovernor(address _newPendingGovernor) external onlyGovernor {
        // Save previous value into the stack to put it into the event later
        address oldPendingGovernor = chainStorage.pendingGovernor;
        // Change pending governor
        chainStorage.pendingGovernor = _newPendingGovernor;
        emit NewPendingGovernor(oldPendingGovernor, _newPendingGovernor);
    }

    /// @notice Accepts transfer of governor rights. Only pending governor can accept the role.
    function acceptGovernor() external {
        address pendingGovernor = chainStorage.pendingGovernor;
        require(msg.sender == pendingGovernor, "n4"); // Only proposed by current governor address can claim the governor rights

        address previousGovernor = chainStorage.governor;
        chainStorage.governor = pendingGovernor;
        delete chainStorage.pendingGovernor;

        emit NewPendingGovernor(pendingGovernor, address(0));
        emit NewGovernor(previousGovernor, pendingGovernor);
    }

    /// @notice Starts the transfer of admin rights. Only the current governor or admin can propose a new pending one.
    /// @notice New admin can accept admin rights by calling `acceptAdmin` function.
    /// @param _newPendingAdmin Address of the new admin
    function setPendingAdmin(address _newPendingAdmin) external onlyGovernorOrAdmin {
        // Save previous value into the stack to put it into the event later
        address oldPendingAdmin = chainStorage.pendingAdmin;
        // Change pending admin
        chainStorage.pendingAdmin = _newPendingAdmin;
        emit NewPendingAdmin(oldPendingAdmin, _newPendingAdmin);
    }

    /// @notice Accepts transfer of admin rights. Only pending admin can accept the role.
    function acceptAdmin() external {
        address pendingAdmin = chainStorage.pendingAdmin;
        require(msg.sender == pendingAdmin, "n4"); // Only proposed by current admin address can claim the admin rights

        address previousAdmin = chainStorage.admin;
        chainStorage.admin = pendingAdmin;
        delete chainStorage.pendingAdmin;

        emit NewPendingAdmin(pendingAdmin, address(0));
        emit NewAdmin(previousAdmin, pendingAdmin);
    }

    /// @notice Change validator status (active or not active)
    /// @param _validator Validator address
    /// @param _active Active flag
    function setValidator(address _validator, bool _active) external onlyGovernorOrAdmin {
        chainStorage.validators[_validator] = _active;
        emit ValidatorStatusUpdate(_validator, _active);
    }

    /// @notice Change zk porter availability
    /// @param _zkPorterIsAvailable The availability of zk porter shard
    function setPorterAvailability(bool _zkPorterIsAvailable) external onlyStateTransition {
        // Change the porter availability
        chainStorage.zkPorterIsAvailable = _zkPorterIsAvailable;
        emit IsPorterAvailableStatusUpdate(_zkPorterIsAvailable);
    }

    /// @notice Change the max L2 gas limit for L1 -> L2 transactions
    /// @param _newPriorityTxMaxGasLimit The maximum number of L2 gas that a user can request for L1 -> L2 transactions
    function setPriorityTxMaxGasLimit(uint256 _newPriorityTxMaxGasLimit) external onlyGovernor {
        require(_newPriorityTxMaxGasLimit <= L2_TX_MAX_GAS_LIMIT, "n5");

        uint256 oldPriorityTxMaxGasLimit = chainStorage.priorityTxMaxGasLimit;
        chainStorage.priorityTxMaxGasLimit = _newPriorityTxMaxGasLimit;
        emit NewPriorityTxMaxGasLimit(oldPriorityTxMaxGasLimit, _newPriorityTxMaxGasLimit);
    }

    /*//////////////////////////////////////////////////////////////
                            UPGRADE EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Executes a proposed governor upgrade
    /// @dev Only the current governor can execute the upgrade
    /// @param _diamondCut The diamond cut parameters to be executed
    function executeUpgrade(Diamond.DiamondCutData calldata _diamondCut) external onlyStateTransition {
        Diamond.diamondCut(_diamondCut);
        emit ExecuteUpgrade(_diamondCut);
    }

    /// @notice Executes a proposed governor upgrade
    /// @dev Only the current governor can execute the upgrade
    /// @param _diamondCut The diamond cut parameters to be executed
    function executeChainIdUpgrade(
        Diamond.DiamondCutData calldata _diamondCut,
        L2CanonicalTransaction memory _l2ProtocolUpgradeTx,
        uint256 _protocolVersion
    ) external onlyStateTransition {
        Diamond.diamondCut(_diamondCut);
        emit SetChainIdUpgrade(_l2ProtocolUpgradeTx, block.timestamp, _protocolVersion);
    }

    /*//////////////////////////////////////////////////////////////
                            CONTRACT FREEZING
    //////////////////////////////////////////////////////////////*/

    /// @notice Instantly pause the functionality of all freezable facets & their selectors
    /// @dev Only the governance mechanism may freeze Diamond Proxy
    function freezeDiamond() external onlyGovernorOrStateTransition {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        require(!diamondStorage.isFrozen, "a9"); // diamond proxy is frozen already
        diamondStorage.isFrozen = true;

        emit Freeze();
    }

    /// @notice Unpause the functionality of all freezable facets & their selectors
    /// @dev Both the governor and its owner can unfreeze Diamond Proxy
    function unfreezeDiamond() external onlyGovernorOrAdmin {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        require(diamondStorage.isFrozen, "a7"); // diamond proxy is not frozen
        diamondStorage.isFrozen = false;

        emit Unfreeze();
    }
}
