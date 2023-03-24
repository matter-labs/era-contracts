// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../common/interfaces/IAllowList.sol";
import "../Verifier.sol";
import "../Storage.sol";

interface IGovernance {
    function setPendingGovernor(address _newPendingGovernor) external;

    function acceptGovernor() external;

    function setValidator(address _validator, bool _active) external;

    function setL2BootloaderBytecodeHash(bytes32 _l2BootloaderBytecodeHash) external;

    function setL2DefaultAccountBytecodeHash(bytes32 _l2DefaultAccountBytecodeHash) external;

    function setPorterAvailability(bool _zkPorterIsAvailable) external;

    function setVerifier(Verifier _newVerifier) external;

    function setVerifierParams(VerifierParams calldata _newVerifierParams) external;

    function setAllowList(IAllowList _newAllowList) external;

    function setPriorityTxMaxGasLimit(uint256 _newPriorityTxMaxGasLimit) external;

    /// @notice Сhanges to the bytecode that is used in L2 as a bootloader (start program)
    event NewL2BootloaderBytecodeHash(bytes32 indexed previousBytecodeHash, bytes32 indexed newBytecodeHash);

    /// @notice Сhanges to the bytecode that is used in L2 as a default account
    event NewL2DefaultAccountBytecodeHash(bytes32 indexed previousBytecodeHash, bytes32 indexed newBytecodeHash);

    /// @notice Porter availability status changes
    event IsPorterAvailableStatusUpdate(bool isPorterAvailable);

    /// @notice Validator's status changed
    event ValidatorStatusUpdate(address indexed validatorAddress, bool isActive);

    /// @notice pendingGovernor is changed
    /// @dev Also emitted when new governor is accepted and in this case, `newPendingGovernor` would be zero address
    event NewPendingGovernor(address indexed oldPendingGovernor, address indexed newPendingGovernor);

    /// @notice Governor changed
    event NewGovernor(address indexed oldGovernor, address indexed newGovernor);

    /// @notice Verifier address changed
    event NewVerifier(address indexed oldVerifier, address indexed newVerifier);

    /// @notice Verifier address changed
    event NewVerifierParams(VerifierParams oldVerifierParams, VerifierParams newVerifierParams);

    /// @notice Allow list address changed
    event NewAllowList(address indexed oldAllowList, address indexed newAllowList);

    /// @notice Priority transaction max L2 gas limit changed
    event NewPriorityTxMaxGasLimit(uint256 oldPriorityTxMaxGasLimit, uint256 newPriorityTxMaxGasLimit);
}
