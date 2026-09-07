// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {Call} from "./Common.sol";
import {ZeroAddress} from "../common/L1ContractErrors.sol";

/// @title UpgradeExecutorBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Shared authority base for the domain-specific upgrade executors. It holds the
///         ownerships protocol governance used to exercise directly (ChainTypeManagers, the
///         ecosystem ProxyAdmin, ...) behind FIXED, non-delegatecall entrypoints, plus ONE raw-call
///         escape hatch — `forward` — so the authority the executor holds never becomes
///         unreachable.
/// @dev One role, deliberately. An earlier design gated `forward` behind a separately governed
///      "emergency board", but that gate is not implementable in the ZKsync governance model: the
///      `EmergencyUpgradeBoard` does not call targets itself — it submits through the
///      `ProtocolUpgradeHandler`, which performs the calls, and so does every routine proposal.
///      Both routes reach this contract as the same `msg.sender` (the handler), so an on-chain
///      distinction between them does not exist, and a gate on the board's address would have
///      left the hatch permanently dead. `forward` is therefore owner-gated: what guards raw calls
///      is the owner's own governance process (the handler's timelock, the Security Council's
///      veto, or the emergency board's all-of quorum), not this contract. What the fixed
///      entrypoints still guarantee is that the NORMAL upgrade path is object-driven — its inputs
///      are pinned write-once objects and its invariants cannot be bypassed without an explicit,
///      event-logged raw call.
abstract contract UpgradeExecutorBase is Ownable2Step {
    /// @notice Emitted for every raw call forwarded through the escape hatch.
    event CallForwarded(address indexed target, uint256 value, bytes data);

    /// @param _initialOwner The governance executor that drives the fixed domain entrypoints.
    constructor(address _initialOwner) {
        // A zero owner would permanently disable every entrypoint (Ownable2Step cannot hand
        // ownership out of address(0)).
        if (_initialOwner == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_initialOwner);
    }

    /// @notice Escape hatch: forwards raw calls so the authority this executor holds (CTM /
    ///         ProxyAdmin ownership) never becomes unreachable — recovery, ownership succession
    ///         and one-off administrative actions outside the fixed entrypoints. Every call is
    ///         logged, so a bypass of the object-driven path is always visible.
    /// @param _calls The calls to forward, executed in order; reverts on the first failure.
    function forward(Call[] calldata _calls) external payable onlyOwner {
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

    /// @notice The executor may need to hold ETH, e.g. to fund governance-initiated priority
    ///         transactions its domain entrypoints compose.
    receive() external payable {}
}
