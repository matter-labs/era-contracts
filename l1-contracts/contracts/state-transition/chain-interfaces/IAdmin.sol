// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IZkSyncStateTransitionBase} from "../chain-interfaces/IBase.sol";

import {Diamond} from "../libraries/Diamond.sol";
import {FeeParams} from "../chain-deps/ZkSyncStateTransitionStorage.sol";

/// @title The interface of the Admin Contract that controls access rights for contract management.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IAdmin is IZkSyncStateTransitionBase {
    /// @notice Starts the transfer of governor rights. Only the current governor can propose a new pending one.
    /// @notice New governor can accept governor rights by calling `acceptGovernor` function.
    /// @param _newPendingGovernor Address of the new governor
    function setPendingGovernor(address _newPendingGovernor) external;

    /// @notice Accepts transfer of governor rights. Only pending governor can accept the role.
    function acceptGovernor() external;

    /// @notice Change validator status (active or not active)
    /// @param _validator Validator address
    /// @param _active Active flag
    function setValidator(address _validator, bool _active) external;

    /// @notice Change zk porter availability
    /// @param _zkPorterIsAvailable The availability of zk porter shard
    function setPorterAvailability(bool _zkPorterIsAvailable) external;

    /// @notice Change the max L2 gas limit for L1 -> L2 transactions
    /// @param _newPriorityTxMaxGasLimit The maximum number of L2 gas that a user can request for L1 -> L2 transactions
    function setPriorityTxMaxGasLimit(uint256 _newPriorityTxMaxGasLimit) external;

    function upgradeChainFromVersion(
        uint256 _protocolVersion,
        Diamond.DiamondCutData calldata _cutData
    ) external;

    /// @notice Executes a proposed governor upgrade
    /// @dev Only the current governor can execute the upgrade
    /// @param _diamondCut The diamond cut parameters to be executed
    function executeUpgrade(Diamond.DiamondCutData calldata _diamondCut) external;

    /// @notice Instantly pause the functionality of all freezable facets & their selectors
    /// @dev Only the governance mechanism may freeze Diamond Proxy
    function freezeDiamond() external;

    /// @notice Unpause the functionality of all freezable facets & their selectors
    /// @dev Both the governor and its owner can unfreeze Diamond Proxy
    function unfreezeDiamond() external;

    /// @notice Porter availability status changes
    event IsPorterAvailableStatusUpdate(bool isPorterAvailable);

    /// @notice Validator's status changed
    event ValidatorStatusUpdate(address indexed validatorAddress, bool isActive);

    /// @notice pendingGovernor is changed
    /// @dev Also emitted when new governor is accepted and in this case, `newPendingGovernor` would be zero address
    event NewPendingGovernor(address indexed oldPendingGovernor, address indexed newPendingGovernor);

    /// @notice Governor changed
    event NewGovernor(address indexed oldGovernor, address indexed newGovernor);


    /// @notice Priority transaction max L2 gas limit changed
    event NewPriorityTxMaxGasLimit(uint256 oldPriorityTxMaxGasLimit, uint256 newPriorityTxMaxGasLimit);

    /// @notice Fee params for L1->L2 transactions changed
    event NewFeeParams(FeeParams oldFeeParams, FeeParams newFeeParams);

    /// @notice Emitted when an upgrade is executed.
    event ExecuteUpgrade(Diamond.DiamondCutData diamondCut);

    /// @notice Emitted when the contract is frozen.
    event Freeze();

    /// @notice Emitted when the contract is unfrozen.
    event Unfreeze();
}
