// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "./IBase.sol";

import {Diamond} from "../libraries/Diamond.sol";

interface IAdmin is IBase {
    function setPendingGovernor(address _newPendingGovernor) external;

    function acceptGovernor() external;

    function setPendingAdmin(address _newPendingAdmin) external;

    function acceptAdmin() external;

    function setValidator(address _validator, bool _active) external;

    function setPorterAvailability(bool _zkPorterIsAvailable) external;

    function setPriorityTxMaxGasLimit(uint256 _newPriorityTxMaxGasLimit) external;

    function executeUpgrade(Diamond.DiamondCutData calldata _diamondCut) external;

    function freezeDiamond() external;

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

    /// @notice pendingAdmin is changed
    /// @dev Also emitted when new admin is accepted and in this case, `newPendingAdmin` would be zero address
    event NewPendingAdmin(address indexed oldPendingAdmin, address indexed newPendingAdmin);

    /// @notice Admin changed
    event NewAdmin(address indexed oldAdmin, address indexed newAdmin);

    /// @notice Priority transaction max L2 gas limit changed
    event NewPriorityTxMaxGasLimit(uint256 oldPriorityTxMaxGasLimit, uint256 newPriorityTxMaxGasLimit);

    /// @notice Emitted when an upgrade is executed.
    event ExecuteUpgrade(Diamond.DiamondCutData diamondCut);

    /// @notice Emitted when the contract is frozen.
    event Freeze();

    /// @notice Emitted when the contract is unfrozen.
    event Unfreeze();
}
