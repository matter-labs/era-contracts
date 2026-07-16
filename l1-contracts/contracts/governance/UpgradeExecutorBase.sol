// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {Call} from "./Common.sol";

/// @title UpgradeExecutorBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Shared authority base for the domain-specific upgrade executors. It holds the
///         ownerships protocol governance used to exercise directly (ChainTypeManagers, the
///         ecosystem ProxyAdmin, ...) and exposes one escape hatch — `forward` — so governance
///         never loses the ability to act directly on the contracts the executor owns.
/// @dev Domain executors (`CTMUpgradeExecutor`, `EcosystemUpgradeExecutor`) inherit this and add
///      their own FIXED, non-delegatecall entrypoints. There is deliberately no generic
///      `execute(module, data)` delegatecall: the only arbitrary authority is `forward`, which is
///      a plain owner-gated call and carries no permanent arbitrary-`delegatecall` surface.
abstract contract UpgradeExecutorBase is Ownable2Step {
    /// @notice Emitted for every raw call forwarded through the escape hatch.
    event CallForwarded(address indexed target, uint256 value, bytes data);

    /// @param _initialOwner The governance executor that controls this contract.
    constructor(address _initialOwner) {
        _transferOwnership(_initialOwner);
    }

    /// @notice Escape hatch: forwards raw calls so that governance never loses direct control
    ///         over the contracts owned by the executor (one-off actions, emergency paths).
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
