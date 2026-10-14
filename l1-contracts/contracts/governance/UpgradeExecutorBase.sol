// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {Call} from "./Common.sol";
import {IUpgradeExecutorBase} from "./IUpgradeExecutorBase.sol";
import {ZeroAddress} from "../common/L1ContractErrors.sol";

/// @title UpgradeExecutorBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Shared authority base for the domain-specific upgrade executors. It holds ownerships on
///         governance's behalf (ChainTypeManagers, the ecosystem ProxyAdmin, ...) behind FIXED,
///         non-delegatecall entrypoints, plus ONE raw-call escape hatch — `forward` — so the
///         authority the executor holds never becomes unreachable.
/// @dev One role: `forward` is gated on the owner alone — see "Authority" in
///      {docs/registry-driven-upgrades.md}.
abstract contract UpgradeExecutorBase is Ownable2Step, IUpgradeExecutorBase {
    /// @param _initialOwner The governance executor that drives the fixed domain entrypoints.
    constructor(address _initialOwner) {
        // A zero owner would permanently disable every entrypoint (Ownable2Step cannot hand
        // ownership out of address(0)).
        if (_initialOwner == address(0)) {
            revert ZeroAddress();
        }
        _transferOwnership(_initialOwner);
    }

    /// @inheritdoc IUpgradeExecutorBase
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
