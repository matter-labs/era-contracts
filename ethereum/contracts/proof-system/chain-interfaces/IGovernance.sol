// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/interfaces/IAllowList.sol";
import "../Verifier.sol";
import "../chain-deps/ProofChainStorage.sol";
import "./IBase.sol";

interface IGovernance is IProofChainBase {
    function setPendingGovernor(address _newPendingGovernor) external;

    function acceptGovernor() external;

    function setValidator(address _validator, bool _active) external;

    function setPorterAvailability(bool _zkPorterIsAvailable) external;

    /// @notice pendingGovernor is changed
    /// @dev Also emitted when new governor is accepted and in this case, `newPendingGovernor` would be zero address
    event NewPendingGovernor(address indexed oldPendingGovernor, address indexed newPendingGovernor);

    /// @notice Governor changed
    event NewGovernor(address indexed oldGovernor, address indexed newGovernor);

    /// @notice Priority transaction max L2 gas limit changed
    event NewPriorityTxMaxGasLimit(uint256 oldPriorityTxMaxGasLimit, uint256 newPriorityTxMaxGasLimit);

    /// @notice Validator's status changed
    event ValidatorStatusUpdate(address indexed validatorAddress, bool isActive);

    /// @notice Porter availability status changes
    event IsPorterAvailableStatusUpdate(bool isPorterAvailable);
}
