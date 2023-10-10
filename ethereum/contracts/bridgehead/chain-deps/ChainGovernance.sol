// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../chain-interfaces/IChainGovernance.sol";
import "../../common/libraries/L2ContractHelper.sol";
import "./ChainBase.sol";

/// @title Governance Contract controls access rights for contract management.
/// @author Matter Labs
contract ChainGovernance is IChainGovernance, ChainBase {
    /// @notice Starts the transfer of governor rights. Only the current governor can propose a new pending one.
    /// @notice New governor can accept governor rights by calling `acceptGovernor` function.
    /// @param _newPendingGovernor Address of the new governor
    function setPendingGovernor(address _newPendingGovernor) external onlyGovernor {
        // Save previous value into the stack to put it into the event later
        address oldPendingGovernor = chainStorage.pendingGovernor;

        if (oldPendingGovernor != _newPendingGovernor) {
            // Change pending governor
            chainStorage.pendingGovernor = _newPendingGovernor;

            emit NewPendingGovernor(oldPendingGovernor, _newPendingGovernor);
        }
    }

    /// @notice Accepts transfer of admin rights. Only pending governor can accept the role.
    function acceptGovernor() external {
        address pendingGovernor = chainStorage.pendingGovernor;
        require(msg.sender == pendingGovernor, "n4"); // Only proposed by current governor address can claim the governor rights

        if (pendingGovernor != chainStorage.governor) {
            address previousGovernor = chainStorage.governor;
            chainStorage.governor = pendingGovernor;
            delete chainStorage.pendingGovernor;

            emit NewPendingGovernor(pendingGovernor, address(0));
            emit NewGovernor(previousGovernor, pendingGovernor);
        }
    }

    /// @notice Change the address of the allow list smart contract
    /// @param _newAllowList Allow list smart contract address
    function setAllowList(IAllowList _newAllowList) external onlyGovernor {
        IAllowList oldAllowList = chainStorage.allowList;
        if (oldAllowList != _newAllowList) {
            chainStorage.allowList = _newAllowList;
            emit NewAllowList(address(oldAllowList), address(_newAllowList));
        }
    }
}
