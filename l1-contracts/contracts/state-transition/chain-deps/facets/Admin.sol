// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IAdmin} from "../../chain-interfaces/IAdmin.sol";
import {Diamond} from "../../libraries/Diamond.sol";
import {MAX_GAS_PER_TRANSACTION} from "../../../common/Config.sol";
import {FeeParams, PubdataPricingMode} from "../ZkSyncHyperchainStorage.sol";
import {ZkSyncHyperchainBase} from "./ZkSyncHyperchainBase.sol";
import {IStateTransitionManager} from "../../IStateTransitionManager.sol";
import {Unauthorized, TooMuchGas, PriorityTxPubdataExceedsMaxPubDataPerBatch, InvalidPubdataPricingMode, ProtocolIdMismatch, ChainAlreadyLive, HashMismatch, ProtocolIdNotGreater, DenominatorIsZero, DiamondAlreadyFrozen, DiamondNotFrozen} from "../../../common/L1ContractErrors.sol";

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
        // Only proposed by current admin address can claim the admin rights
        if (msg.sender != pendingAdmin) {
            revert Unauthorized(msg.sender);
        }

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
        if (_newPriorityTxMaxGasLimit > MAX_GAS_PER_TRANSACTION) {
            revert TooMuchGas();
        }

        uint256 oldPriorityTxMaxGasLimit = s.priorityTxMaxGasLimit;
        s.priorityTxMaxGasLimit = _newPriorityTxMaxGasLimit;
        emit NewPriorityTxMaxGasLimit(oldPriorityTxMaxGasLimit, _newPriorityTxMaxGasLimit);
    }

    /// @inheritdoc IAdmin
    function changeFeeParams(FeeParams calldata _newFeeParams) external onlyAdminOrStateTransitionManager {
        // Double checking that the new fee params are valid, i.e.
        // the maximal pubdata per batch is not less than the maximal pubdata per priority transaction.
        if (_newFeeParams.maxPubdataPerBatch < _newFeeParams.priorityTxMaxPubdata) {
            revert PriorityTxPubdataExceedsMaxPubDataPerBatch();
        }

        FeeParams memory oldFeeParams = s.feeParams;

        // we cannot change pubdata pricing mode
        if (_newFeeParams.pubdataPricingMode != oldFeeParams.pubdataPricingMode) {
            revert InvalidPubdataPricingMode();
        }

        s.feeParams = _newFeeParams;

        emit NewFeeParams(oldFeeParams, _newFeeParams);
    }

    /// @inheritdoc IAdmin
    function setTokenMultiplier(uint128 _nominator, uint128 _denominator) external onlyAdminOrStateTransitionManager {
        if (_denominator == 0) {
            revert DenominatorIsZero();
        }
        uint128 oldNominator = s.baseTokenGasPriceMultiplierNominator;
        uint128 oldDenominator = s.baseTokenGasPriceMultiplierDenominator;

        s.baseTokenGasPriceMultiplierNominator = _nominator;
        s.baseTokenGasPriceMultiplierDenominator = _denominator;

        emit NewBaseTokenMultiplier(oldNominator, oldDenominator, _nominator, _denominator);
    }

    /// @inheritdoc IAdmin
    function setPubdataPricingMode(PubdataPricingMode _pricingMode) external onlyAdmin {
        // Validium mode can be set only before the first batch is processed
        if (s.totalBatchesCommitted != 0) {
            revert ChainAlreadyLive();
        }
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
        bytes32 upgradeCutHash = IStateTransitionManager(s.stateTransitionManager).upgradeCutHash(_oldProtocolVersion);
        if (cutHashInput != upgradeCutHash) {
            revert HashMismatch(upgradeCutHash, cutHashInput);
        }

        if (s.protocolVersion != _oldProtocolVersion) {
            revert ProtocolIdMismatch(s.protocolVersion, _oldProtocolVersion);
        }
        Diamond.diamondCut(_diamondCut);
        emit ExecuteUpgrade(_diamondCut);
        if (s.protocolVersion <= _oldProtocolVersion) {
            revert ProtocolIdNotGreater();
        }
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

        // diamond proxy is frozen already
        if (diamondStorage.isFrozen) {
            revert DiamondAlreadyFrozen();
        }
        diamondStorage.isFrozen = true;

        emit Freeze();
    }

    /// @inheritdoc IAdmin
    function unfreezeDiamond() external onlyStateTransitionManager {
        Diamond.DiamondStorage storage diamondStorage = Diamond.getDiamondStorage();

        // diamond proxy is not frozen
        if (!diamondStorage.isFrozen) {
            revert DiamondNotFrozen();
        }
        diamondStorage.isFrozen = false;

        emit Unfreeze();
    }
}
