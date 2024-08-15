// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IChainAdmin} from "./IChainAdmin.sol";
import {IRestriction} from "./IRestriction.sol";
import {Call} from "./Common.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {ReentrancyGuard} from "../common/ReentrancyGuard.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The contract is designed to hold the `admin` role in ZKSync Chain (State Transition) contracts.
/// The owner of the contract can perform any external calls and also save the information needed for
/// the blockchain node to accept the protocol upgrade.
contract ChainAdmin is IChainAdmin, ReentrancyGuard {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice Ensures that only the `ChainAdmin` contract itself can call the function.
    /// @dev All functions that require access-control should use `onlySelf` modifier, while the access control logic
    /// should be implemented in the restriction contracts.
    modifier onlySelf() {
        require(msg.sender == address(this), "Only self");
        _;
    }

    constructor(address[] memory _initialRestrictions) reentrancyGuardInitializer {
        unchecked {
            for (uint256 i = 0; i < _initialRestrictions.length; ++i) {
                _addRestriction(_initialRestrictions[i]);
            }
        }
    }

    /// @notice Mapping of protocol versions to their expected upgrade timestamps.
    /// @dev Needed for the offchain node administration to know when to start building batches with the new protocol version.
    mapping(uint256 protocolVersion => uint256 upgradeTimestamp) public protocolVersionToUpgradeTimestamp;

    /// @notice The address which can call `setTokenMultiplier` function to change the base token gas price in the Chain contract.
    /// @dev The token base price can be changed quite often, so the private key for this role is supposed to be stored in the node
    /// and used by the automated service in a way similar to the sequencer workflow.
    address public tokenMultiplierSetter;

    constructor(address _initialOwner, address _initialTokenMultiplierSetter) {
        require(_initialOwner != address(0), "Initial owner should be non zero address");
        _transferOwnership(_initialOwner);
        // Can be zero if no one has this permission.
        tokenMultiplierSetter = _initialTokenMultiplierSetter;
        emit NewTokenMultiplierSetter(address(0), _initialTokenMultiplierSetter);
    }

    /// @notice The set of active restrictions.
    EnumerableSet.AddressSet internal activeRestrictions;

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
        // slither-disable-next-line unused-return
        activeRestrictions.remove(_restriction);
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
        // solhint-disable-next-line gas-custom-errors
        require(_calls.length > 0, "No calls provided");
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

    /// @notice Sets the token multiplier in the specified Chain contract.
    /// @param _chainContract The chain contract address where the token multiplier will be set.
    /// @param _nominator The numerator part of the token multiplier.
    /// @param _denominator The denominator part of the token multiplier.
    function setTokenMultiplier(IAdmin _chainContract, uint128 _nominator, uint128 _denominator) external {
        require(msg.sender == tokenMultiplierSetter, "Only the token multiplier setter can call this function");
        _chainContract.setTokenMultiplier(_nominator, _denominator);
    }

    /// @dev Contract might receive/hold ETH as part of the maintenance process.
    receive() external payable {}

    /// @notice Function that returns the current admin can perform the call.
    /// @dev By default it always returns true, but can be overridden in derived contracts.
    function _validateCall(Call calldata _call) internal view {
        address[] memory restrictions = getRestrictions();

        unchecked {
            for (uint256 i = 0; i < restrictions.length; ++i) {
                IRestriction(restrictions[i]).validateCall(_call, msg.sender);
            }
        }
    }

    /// @notice Adds a new restriction to the active restrictions set.
    /// @param _restriction The address of the restriction contract to be added.
    function _addRestriction(address _restriction) internal {
        // slither-disable-next-line unused-return
        activeRestrictions.add(_restriction);
    }
}
