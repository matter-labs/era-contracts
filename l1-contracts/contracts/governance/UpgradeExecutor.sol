// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";

import {Call} from "./Common.sol";
import {IUpgradeExecutor} from "./IUpgradeExecutor.sol";
import {AddressHasNoCode, ModuleAlteredOwnership} from "../common/L1ContractErrors.sol";

/// @title UpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The permanent authority keystone of registry-driven protocol upgrades. It holds the
///         ownerships that protocol governance used to exercise directly (ChainTypeManagers,
///         the ecosystem ProxyAdmin, ValidatorTimelocks, ...), and exposes exactly two
///         governance-gated entrypoints:
///         - `execute`: delegatecall a stateless, per-upgrade orchestrator module that composes
///           and performs every upgrade call from a registry;
///         - `forward`: an escape hatch of raw calls, so governance never loses the ability to
///           act directly on the contracts the executor owns.
/// @dev The owner is expected to be the protocol governance executor (e.g. the
///      ProtocolUpgradeHandler). This contract deliberately has no storage beyond the two
///      Ownable slots, so a delegatecalled module cannot clobber any other executor state;
///      the ownership slots themselves are checked after every module run.
contract UpgradeExecutor is IUpgradeExecutor, Ownable2Step {
    /// @param _initialOwner The governance executor that controls this contract.
    constructor(address _initialOwner) {
        _transferOwnership(_initialOwner);
    }

    /// @inheritdoc IUpgradeExecutor
    function execute(
        address _module,
        bytes calldata _data
    ) external payable onlyOwner returns (bytes memory returnData) {
        // A delegatecall to an address without code succeeds silently; a module must have code.
        if (_module.code.length == 0) {
            revert AddressHasNoCode(_module);
        }

        address ownerBefore = owner();
        address pendingOwnerBefore = pendingOwner();

        bool success;
        // solhint-disable-next-line avoid-low-level-calls
        (success, returnData) = _module.delegatecall(_data);
        if (!success) {
            // Propagate an error if the module reverts.
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }

        // Modules run with this contract's storage; the only slots that exist are the ownership
        // slots, and no module may touch them.
        if (owner() != ownerBefore || pendingOwner() != pendingOwnerBefore) {
            revert ModuleAlteredOwnership();
        }

        emit UpgradeModuleExecuted(_module, _data);
    }

    /// @inheritdoc IUpgradeExecutor
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
    ///         transactions composed by orchestrator modules.
    receive() external payable {}
}
