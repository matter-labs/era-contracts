// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IAdmin} from "../../chain-interfaces/IAdmin.sol";
import {Diamond} from "../../libraries/Diamond.sol";
import {MAX_GAS_PER_TRANSACTION} from "../../../common/Config.sol";
import {FeeParams} from "../ZkSyncStateTransitionStorage.sol";
import {ZkSyncStateTransitionBase} from "./Base.sol";
import {IStateTransitionManager} from "../../IStateTransitionManager.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZkSyncStateTransitionBase} from "../../chain-interfaces/IBase.sol";

/// @title Admin Contract controls access rights for contract management.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract AdminFacet is ZkSyncStateTransitionBase, IAdmin {
    /// @inheritdoc IZkSyncStateTransitionBase
    string public constant override getName = "AdminFacet";

    /// @inheritdoc IAdmin
    function setPendingGovernor(address _newPendingGovernor) external onlyGovernor {
        // Save previous value into the stack to put it into the event later
        address oldPendingGovernor = s.pendingGovernor;
        // Change pending governor
        s.pendingGovernor = _newPendingGovernor;
        emit NewPendingGovernor(oldPendingGovernor, _newPendingGovernor);
    }

    /// @inheritdoc IAdmin
    function acceptGovernor() external {
        address pendingGovernor = s.pendingGovernor;
        require(msg.sender == pendingGovernor, "n4"); // Only proposed by current governor address can claim the governor rights

        address previousGovernor = s.governor;
        s.governor = pendingGovernor;
        delete s.pendingGovernor;

        emit NewPendingGovernor(pendingGovernor, address(0));
        emit NewGovernor(previousGovernor, pendingGovernor);
    }

    /// @inheritdoc IAdmin
    function setValidator(address _validator, bool _active) external onlyStateTransitionManager {
        s.validators[_validator] = _active;
        emit ValidatorStatusUpdate(_validator, _active);
    }

    /// @inheritdoc IAdmin
    function setPorterAvailability(bool _zkPorterIsAvailable) external onlyStateTransitionManager {
        // Change the porter availability
        s.zkPorterIsAvailable = _zkPorterIsAvailable;
        emit IsPorterAvailableStatusUpdate(_zkPorterIsAvailable);
    }

    /// @inheritdoc IAdmin
    function setPriorityTxMaxGasLimit(uint256 _newPriorityTxMaxGasLimit) external onlyStateTransitionManager {
        require(_newPriorityTxMaxGasLimit <= MAX_GAS_PER_TRANSACTION, "n5");

        uint256 oldPriorityTxMaxGasLimit = s.priorityTxMaxGasLimit;
        s.priorityTxMaxGasLimit = _newPriorityTxMaxGasLimit;
        emit NewPriorityTxMaxGasLimit(oldPriorityTxMaxGasLimit, _newPriorityTxMaxGasLimit);
    }

    /// @notice Change the fee params for L1->L2 transactions
    /// @param _newFeeParams The new fee params
    function changeFeeParams(FeeParams calldata _newFeeParams) external onlyGovernorOrStateTransitionManager {
        // Double checking that the new fee params are valid, i.e.
        // the maximal pubdata per batch is not less than the maximal pubdata per priority transaction.
        require(_newFeeParams.maxPubdataPerBatch >= _newFeeParams.priorityTxMaxPubdata, "n6");

        FeeParams memory oldFeeParams = s.feeParams;
        s.feeParams = _newFeeParams;

        emit NewFeeParams(oldFeeParams, _newFeeParams);
    }

    /*//////////////////////////////////////////////////////////////
                            UPGRADE EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// upgrade a specific chain
    function upgradeChainFromVersion(
        uint256 _oldProtocolVersion,
        Diamond.DiamondCutData calldata _diamondCut
    ) external onlyGovernorOrStateTransitionManager {
        bytes32 cutHashInput = keccak256(abi.encode(_diamondCut));
        require(
            cutHashInput == IStateTransitionManager(s.stateTransitionManager).upgradeCutHash(_oldProtocolVersion),
            "StateTransition: cutHash mismatch"
        );

        require(
            s.protocolVersion == _oldProtocolVersion,
            "StateTransition: protocolVersion mismatch in STC when upgrading"
        );
        Diamond.diamondCut(_diamondCut);
        emit ExecuteUpgrade(_diamondCut);
        require(
            s.protocolVersion > _oldProtocolVersion,
            "StateTransition: protocolVersion mismatch in STC after upgrading"
        );
    }

    /// @inheritdoc IAdmin
    function executeUpgrade(Diamond.DiamondCutData calldata _diamondCut) external onlyStateTransitionManager {
        Diamond.diamondCut(_diamondCut);
        emit ExecuteUpgrade(_diamondCut);
    }

    /*//////////////////////////////////////////////////////////////
                            CONTRACT FREEZING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdmin
    function freezeDiamond() external onlyGovernorOrStateTransitionManager {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        require(!diamondStorage.isFrozen, "a9"); // diamond proxy is frozen already
        diamondStorage.isFrozen = true;

        emit Freeze();
    }

    /// @inheritdoc IAdmin
    function unfreezeDiamond() external onlyGovernorOrStateTransitionManager {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        require(diamondStorage.isFrozen, "a7"); // diamond proxy is not frozen
        diamondStorage.isFrozen = false;

        emit Unfreeze();
    }
}
