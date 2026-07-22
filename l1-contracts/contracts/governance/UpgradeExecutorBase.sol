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
///      - `breakGlassGovernor` alone can `forward` raw calls, which CAN bypass every transition
///        invariant through direct CTM / ProxyAdmin calls. With the same holder for both roles
///        the separation is only auditability; its value is realized by giving break-glass to a
///        differently-governed holder (e.g. a security council with its own process).
abstract contract UpgradeExecutorBase is Ownable2Step {
    /// @notice The only authority allowed to forward raw calls (break-glass).
    address public breakGlassGovernor;
    /// @notice Two-step handover guard for the break-glass role.
    address public pendingBreakGlassGovernor;

    /// @notice Emitted for every raw call forwarded through the break-glass hatch.
    event CallForwarded(address indexed target, uint256 value, bytes data);
    /// @notice Emitted when the break-glass role is offered to a new holder.
    event BreakGlassGovernorTransferStarted(address indexed current, address indexed pending);
    /// @notice Emitted when the break-glass role changes holder.
    event BreakGlassGovernorTransferred(address indexed previous, address indexed current);

    modifier onlyBreakGlass() {
        if (msg.sender != breakGlassGovernor) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @param _initialOwner The governance executor that drives the fixed domain entrypoints.
    /// @param _breakGlassGovernor The separately governed break-glass authority.
    constructor(address _initialOwner, address _breakGlassGovernor) {
        // A zero owner would permanently disable every fixed upgrade entrypoint (Ownable2Step
        // cannot hand ownership out of address(0)), leaving break-glass as the only authority.
        if (_initialOwner == address(0) || _breakGlassGovernor == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_initialOwner);
        breakGlassGovernor = _breakGlassGovernor;
        emit BreakGlassGovernorTransferred(address(0), _breakGlassGovernor);
    }

    /// @notice Break-glass: forwards raw calls so the authority this executor holds (CTM /
    ///         ProxyAdmin ownership) never becomes unreachable — emergency paths and one-off
    ///         administrative actions outside the fixed upgrade entrypoints.
    /// @param _calls The calls to forward, executed in order; reverts on the first failure.
    function forward(Call[] calldata _calls) external payable onlyBreakGlass {
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
    function transferBreakGlassGovernor(address _newGovernor) external onlyBreakGlass {
        pendingBreakGlassGovernor = _newGovernor;
        emit BreakGlassGovernorTransferStarted(breakGlassGovernor, _newGovernor);
    }

    /// @notice Accepts the break-glass role.
    function acceptBreakGlassGovernor() external {
        if (msg.sender != pendingBreakGlassGovernor) {
            revert Unauthorized(msg.sender);
        }
        emit BreakGlassGovernorTransferred(breakGlassGovernor, msg.sender);
        breakGlassGovernor = msg.sender;
        pendingBreakGlassGovernor = address(0);
    }

    /// @notice The executor may need to hold ETH, e.g. to fund governance-initiated priority
    ///         transactions its domain entrypoints compose.
    receive() external payable {}
}
