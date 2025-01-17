// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable gas-length-in-loops

import {NoCallsProvided, OnlySelfAllowed, RestrictionWasNotPresent, RestrictionWasAlreadyPresent} from "../common/L1ContractErrors.sol";
import {IChainAdmin} from "./IChainAdmin.sol";
import {Restriction} from "./restriction/Restriction.sol";
import {RestrictionValidator} from "./restriction/RestrictionValidator.sol";
import {Call} from "./Common.sol";

import {EnumerableSet} from "@openzeppelin/contracts-v4/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The contract is designed to hold the `admin` role in ZKSync Chain (State Transition) contracts.
/// @dev Note, that it does not implement any form of access control by default, but instead utilizes
/// so called "restrictions": contracts that implement the `IRestriction` interface and ensure that
/// particular restrictions are ensured for the contract, including access control, security invariants, etc.
/// @dev This is a new EXPERIMENTAL version of the `ChainAdmin` implementation. While chains may opt into using it,
/// using the old `ChainAdminOwnable` is recommended.
contract ChainAdmin is IChainAdmin, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Mapping of protocol versions to their expected upgrade timestamps.
    /// @dev Needed for the offchain node administration to know when to start building batches with the new protocol version.
    mapping(uint256 protocolVersion => uint256 upgradeTimestamp) public protocolVersionToUpgradeTimestamp;

    /// @notice The set of active restrictions.
    EnumerableSet.AddressSet internal activeRestrictions;

    /// @notice Ensures that only the `ChainAdmin` contract itself can call the function.
    /// @dev All functions that require access-control should use `onlySelf` modifier, while the access control logic
    /// should be implemented in the restriction contracts.
    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert OnlySelfAllowed();
        }
        _;
    }

    constructor(address[] memory _initialRestrictions) reentrancyGuardInitializer {
        unchecked {
            for (uint256 i = 0; i < _initialRestrictions.length; ++i) {
                _addRestriction(_initialRestrictions[i]);
            }
        }
    }

    /// @notice Returns the list of active restrictions.
    function getRestrictions() public view returns (address[] memory) {
        return activeRestrictions.values();
    }

    /// @inheritdoc IChainAdmin
    function isRestrictionActive(address _restriction) external view returns (bool) {
        return activeRestrictions.contains(_restriction);
    }

    /// @inheritdoc IChainAdmin
    function addRestriction(address _restriction) external onlySelf {
        _addRestriction(_restriction);
    }

    /// @inheritdoc IChainAdmin
    function removeRestriction(address _restriction) external onlySelf {
        if (!activeRestrictions.remove(_restriction)) {
            revert RestrictionWasNotPresent(_restriction);
        }
        emit RestrictionRemoved(_restriction);
    }

    /// @notice Set the expected upgrade timestamp for a specific protocol version.
    /// @param _protocolVersion The ZKsync chain protocol version.
    /// @param _upgradeTimestamp The timestamp at which the chain node should expect the upgrade to happen.
    function setUpgradeTimestamp(uint256 _protocolVersion, uint256 _upgradeTimestamp) external onlySelf {
        protocolVersionToUpgradeTimestamp[_protocolVersion] = _upgradeTimestamp;
        emit UpdateUpgradeTimestamp(_protocolVersion, _upgradeTimestamp);
    }

    /// @notice Execute multiple calls as part of contract administration.
    /// @param _calls Array of Call structures defining target, value, and data for each call.
    /// @param _requireSuccess If true, reverts transaction on any call failure.
    /// @dev Intended for batch processing of contract interactions, managing gas efficiency and atomicity of operations.
    /// @dev Note, that this function lacks access control. It is expected that the access control is implemented in a separate restriction contract.
    /// @dev Even though all the validation from external modules is executed via `staticcall`, the function
    /// is marked as `nonReentrant` to prevent reentrancy attacks in case the staticcall restriction is lifted in the future.
    function multicall(Call[] calldata _calls, bool _requireSuccess) external payable nonReentrant {
        if (_calls.length == 0) {
            revert NoCallsProvided();
        }
        for (uint256 i = 0; i < _calls.length; ++i) {
            _validateCall(_calls[i]);

            // slither-disable-next-line arbitrary-send-eth
            (bool success, bytes memory returnData) = _calls[i].target.call{value: _calls[i].value}(_calls[i].data);
            if (_requireSuccess && !success) {
                // Propagate an error if the call fails.
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
            emit CallExecuted(_calls[i], success, returnData);
        }
    }

    /// @dev Contract might receive/hold ETH as part of the maintenance process.
    receive() external payable {}

    /// @notice Function that ensures that the current admin can perform the call.
    /// @dev Reverts in case the call can not be performed. Successfully executes otherwise
    function _validateCall(Call calldata _call) private view {
        address[] memory restrictions = getRestrictions();

        unchecked {
            for (uint256 i = 0; i < restrictions.length; ++i) {
                Restriction(restrictions[i]).validateCall(_call, msg.sender);
            }
        }
    }

    /// @notice Adds a new restriction to the active restrictions set.
    /// @param _restriction The address of the restriction contract to be added.
    function _addRestriction(address _restriction) private {
        RestrictionValidator.validateRestriction(_restriction);

        if (!activeRestrictions.add(_restriction)) {
            revert RestrictionWasAlreadyPresent(_restriction);
        }
        emit RestrictionAdded(_restriction);
    }
}
