// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IAdmin} from "../../chain-interfaces/IAdmin.sol";
import {Diamond} from "../../libraries/Diamond.sol";
import {MAX_GAS_PER_TRANSACTION} from "../../../common/Config.sol";
import {FeeParams, PubdataPricingMode} from "../ZkSyncHyperchainStorage.sol";
import {ZkSyncHyperchainBase} from "./ZkSyncHyperchainBase.sol";
import {IStateTransitionManager} from "../../IStateTransitionManager.sol";

// While formally the following import is not used, it is needed to inherit documentation from it
import {IZkSyncHyperchainBase} from "../../chain-interfaces/IZkSyncHyperchainBase.sol";

/// @title Admin Contract controls access rights for contract management.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract AdminFacet is ZkSyncHyperchainBase, IAdmin {
    /// @inheritdoc IZkSyncHyperchainBase
    string public constant override getName = "AdminFacet";

    /// @inheritdoc IAdmin
    function setPendingAdmin(address _newPendingAdmin) external onlyAdmin {
        // Save previous value into the stack to put it into the event later
        address oldPendingAdmin = s.pendingAdmin;
        // Change pending admin
        s.pendingAdmin = _newPendingAdmin;
        emit NewPendingAdmin(oldPendingAdmin, _newPendingAdmin);
    }

    /// @inheritdoc IAdmin
    function acceptAdmin() external {
        address pendingAdmin = s.pendingAdmin;
        require(msg.sender == pendingAdmin, "n4"); // Only proposed by current admin address can claim the admin rights

        address previousAdmin = s.admin;
        s.admin = pendingAdmin;
        delete s.pendingAdmin;

        emit NewPendingAdmin(pendingAdmin, address(0));
        emit NewAdmin(previousAdmin, pendingAdmin);
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

    /// @inheritdoc IAdmin
    function changeFeeParams(FeeParams calldata _newFeeParams) external onlyAdminOrStateTransitionManager {
        // Double checking that the new fee params are valid, i.e.
        // the maximal pubdata per batch is not less than the maximal pubdata per priority transaction.
        require(_newFeeParams.maxPubdataPerBatch >= _newFeeParams.priorityTxMaxPubdata, "n6");

        FeeParams memory oldFeeParams = s.feeParams;

        require(_newFeeParams.pubdataPricingMode == oldFeeParams.pubdataPricingMode, "n7"); // we cannot change pubdata pricing mode

        s.feeParams = _newFeeParams;

        emit NewFeeParams(oldFeeParams, _newFeeParams);
    }

    /// @inheritdoc IAdmin
    function setTokenMultiplier(uint128 _nominator, uint128 _denominator) external onlyAdminOrStateTransitionManager {
        require(_denominator != 0, "AF: denominator 0");
        uint128 oldNominator = s.baseTokenGasPriceMultiplierNominator;
        uint128 oldDenominator = s.baseTokenGasPriceMultiplierDenominator;

        s.baseTokenGasPriceMultiplierNominator = _nominator;
        s.baseTokenGasPriceMultiplierDenominator = _denominator;

        emit NewBaseTokenMultiplier(oldNominator, oldDenominator, _nominator, _denominator);
    }

    /// @inheritdoc IAdmin
    function setPubdataPricingMode(PubdataPricingMode _pricingMode) external onlyAdmin {
        require(s.totalBatchesCommitted == 0, "AdminFacet: set validium only after genesis"); // Validium mode can be set only before the first batch is processed
        s.feeParams.pubdataPricingMode = _pricingMode;
        emit ValidiumModeStatusUpdate(_pricingMode);
    }

    function setTransactionFilterer(address _transactionFilterer) external onlyAdmin {
        address oldTransactionFilterer = s.transactionFilterer;
        s.transactionFilterer = _transactionFilterer;
        emit NewTransactionFilterer(oldTransactionFilterer, _transactionFilterer);
    }

    /*//////////////////////////////////////////////////////////////
                            UPGRADE EXECUTION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAdmin
    function upgradeChainFromVersion(
        uint256 _oldProtocolVersion,
        Diamond.DiamondCutData calldata _diamondCut
    ) external onlyAdminOrStateTransitionManager {
        bytes32 cutHashInput = keccak256(abi.encode(_diamondCut));
        require(
            cutHashInput == IStateTransitionManager(s.stateTransitionManager).upgradeCutHash(_oldProtocolVersion),
            "AdminFacet: cutHash mismatch"
        );

        require(s.protocolVersion == _oldProtocolVersion, "AdminFacet: protocolVersion mismatch in STC when upgrading");
        Diamond.diamondCut(_diamondCut);
        emit ExecuteUpgrade(_diamondCut);
        require(s.protocolVersion > _oldProtocolVersion, "AdminFacet: protocolVersion mismatch in STC after upgrading");
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
    function freezeDiamond() external onlyStateTransitionManager {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        require(!diamondStorage.isFrozen, "a9"); // diamond proxy is frozen already
        diamondStorage.isFrozen = true;

        emit Freeze();
    }

    /// @inheritdoc IAdmin
    function unfreezeDiamond() external onlyStateTransitionManager {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        require(diamondStorage.isFrozen, "a7"); // diamond proxy is not frozen
        diamondStorage.isFrozen = false;

        emit Unfreeze();
    }
}
