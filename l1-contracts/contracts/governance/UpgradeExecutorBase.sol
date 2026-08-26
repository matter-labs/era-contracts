// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {Call} from "./Common.sol";
import {Unauthorized, ZeroAddress} from "../common/L1ContractErrors.sol";

/// @title UpgradeExecutorBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Shared authority base for the domain-specific upgrade executors. It holds the
///         ownerships protocol governance used to exercise directly (ChainTypeManagers, the
///         ecosystem ProxyAdmin, ...) behind FIXED, non-delegatecall entrypoints, plus one
///         SEPARATELY GOVERNED break-glass capability — `forward` — so the raw authority the
///         executor holds never becomes unreachable.
/// @dev Two distinct roles, deliberately:
///      - `owner` (Ownable2Step) drives the fixed domain entrypoints — the normal upgrade path,
///        whose inputs are pinned write-once objects and whose invariants cannot be bypassed;
///      - `emergencyUpgradeBoard` alone can `forward` raw calls, which CAN bypass every transition
///        invariant through direct CTM / ProxyAdmin calls.
/// @dev In the ZKsync ecosystem `owner` is the `ProtocolUpgradeHandler` and `emergencyUpgradeBoard`
///      is the `EmergencyUpgradeBoard` — NOT the Security Council on its own, which cannot act
///      unilaterally: the board's `executeEmergencyUpgrade` requires the Security Council, the
///      Guardians and the Foundation multisig to sign the same upgrade. That is the point of the
///      split: the escape hatch must not share a failure mode with the standard path, so a
///      Governance that is stuck, captured or holding a bad queue still leaves a differently
///      governed route to the CTM. Pointing both roles at the same holder collapses the
///      separation to mere auditability.
abstract contract UpgradeExecutorBase is Ownable2Step {
    /// @notice The only authority allowed to forward raw calls — the break-glass hatch.
    address public emergencyUpgradeBoard;
    /// @notice Two-step handover guard for the emergency upgrade board role.
    address public pendingEmergencyUpgradeBoard;

    /// @notice Emitted for every raw call forwarded through the break-glass hatch.
    event CallForwarded(address indexed target, uint256 value, bytes data);
    /// @notice Emitted when the emergency upgrade board role is offered to a new holder.
    event EmergencyUpgradeBoardTransferStarted(address indexed current, address indexed pending);
    /// @notice Emitted when the emergency upgrade board role changes holder.
    event EmergencyUpgradeBoardTransferred(address indexed previous, address indexed current);

    modifier onlyEmergencyUpgradeBoard() {
        if (msg.sender != emergencyUpgradeBoard) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @param _initialOwner The governance executor that drives the fixed domain entrypoints.
    /// @param _emergencyUpgradeBoard The separately governed break-glass authority (see the contract docs).
    constructor(address _initialOwner, address _emergencyUpgradeBoard) {
        // A zero owner would permanently disable every fixed upgrade entrypoint (Ownable2Step
        // cannot hand ownership out of address(0)), leaving break-glass as the only authority.
        if (_initialOwner == address(0) || _emergencyUpgradeBoard == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_initialOwner);
        emergencyUpgradeBoard = _emergencyUpgradeBoard;
        emit EmergencyUpgradeBoardTransferred(address(0), _emergencyUpgradeBoard);
    }

    /// @notice Break-glass: forwards raw calls so the authority this executor holds (CTM /
    ///         ProxyAdmin ownership) never becomes unreachable — emergency paths and one-off
    ///         administrative actions outside the fixed upgrade entrypoints.
    /// @param _calls The calls to forward, executed in order; reverts on the first failure.
    function forward(Call[] calldata _calls) external payable onlyEmergencyUpgradeBoard {
        // We disable this check because calldata array length is cheap.
        // solhint-disable-next-line gas-length-in-loops
        for (uint256 i = 0; i < _calls.length; ++i) {
            // slither-disable-next-line arbitrary-send-eth
            (bool success, bytes memory returnData) = _calls[i].target.call{value: _calls[i].value}(_calls[i].data);
            if (!success) {
                // Propagate an error if the call fails.
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
            emit CallForwarded(_calls[i].target, _calls[i].value, _calls[i].data);
        }
    }

    /// @notice Offers the break-glass role to `_newGovernor` (two-step, like ownership).
    function transferEmergencyUpgradeBoard(address _newGovernor) external onlyEmergencyUpgradeBoard {
        pendingEmergencyUpgradeBoard = _newGovernor;
        emit EmergencyUpgradeBoardTransferStarted(emergencyUpgradeBoard, _newGovernor);
    }

    /// @notice Accepts the break-glass role.
    function acceptEmergencyUpgradeBoard() external {
        if (msg.sender != pendingEmergencyUpgradeBoard) {
            revert Unauthorized(msg.sender);
        }
        emit EmergencyUpgradeBoardTransferred(emergencyUpgradeBoard, msg.sender);
        emergencyUpgradeBoard = msg.sender;
        pendingEmergencyUpgradeBoard = address(0);
    }

    /// @notice The executor may need to hold ETH, e.g. to fund governance-initiated priority
    ///         transactions its domain entrypoints compose.
    receive() external payable {}
}
