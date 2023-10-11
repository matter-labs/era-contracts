// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../bridgehead-interfaces/IBridgeheadAdmin.sol";
import "../../common/libraries/Diamond.sol";
import "../../common/libraries/L2ContractHelper.sol";
import "./BridgeheadBase.sol";

/// @title Admin Contract controls access rights for contract management.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract BridgeheadAdminFacet is BridgeheadBase, IBridgeheadAdmin {
    string public constant override getName = "BridgeheadAdminFacet";

    /// @notice Starts the transfer of governor rights. Only the current governor can propose a new pending one.
    /// @notice New governor can accept governor rights by calling `acceptGovernor` function.
    /// @param _newPendingGovernor Address of the new governor
    function setPendingGovernor(address _newPendingGovernor) external onlyGovernor {
        // Save previous value into the stack to put it into the event later
        address oldPendingGovernor = bridgeheadStorage.pendingGovernor;
        // Change pending governor
        bridgeheadStorage.pendingGovernor = _newPendingGovernor;
        emit NewPendingGovernor(oldPendingGovernor, _newPendingGovernor);
    }

    /// @notice Accepts transfer of governor rights. Only pending governor can accept the role.
    function acceptGovernor() external {
        address pendingGovernor = bridgeheadStorage.pendingGovernor;
        require(msg.sender == pendingGovernor, "n4"); // Only proposed by current governor address can claim the governor rights

        address previousGovernor = bridgeheadStorage.governor;
        bridgeheadStorage.governor = pendingGovernor;
        delete bridgeheadStorage.pendingGovernor;

        emit NewPendingGovernor(pendingGovernor, address(0));
        emit NewGovernor(previousGovernor, pendingGovernor);
    }

    /// @notice Starts the transfer of admin rights. Only the current governor or admin can propose a new pending one.
    /// @notice New admin can accept admin rights by calling `acceptAdmin` function.
    /// @param _newPendingAdmin Address of the new admin
    function setPendingAdmin(address _newPendingAdmin) external onlyGovernorOrAdmin {
        // Save previous value into the stack to put it into the event later
        address oldPendingAdmin = bridgeheadStorage.pendingAdmin;
        // Change pending admin
        bridgeheadStorage.pendingAdmin = _newPendingAdmin;
        emit NewPendingGovernor(oldPendingAdmin, _newPendingAdmin);
    }

    /// @notice Accepts transfer of admin rights. Only pending admin can accept the role.
    function acceptAdmin() external {
        address pendingAdmin = bridgeheadStorage.pendingAdmin;
        require(msg.sender == pendingAdmin, "n4"); // Only proposed by current admin address can claim the admin rights

        address previousAdmin = bridgeheadStorage.admin;
        bridgeheadStorage.admin = pendingAdmin;
        delete bridgeheadStorage.pendingAdmin;

        emit NewPendingAdmin(pendingAdmin, address(0));
        emit NewAdmin(previousAdmin, pendingAdmin);
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
    function unfreezeDiamond() external onlyGovernorOrAdmin {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        require(diamondStorage.isFrozen, "a7"); // diamond proxy is not frozen
        diamondStorage.isFrozen = false;

        emit Unfreeze();
    }
}
