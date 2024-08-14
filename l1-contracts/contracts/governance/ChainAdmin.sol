// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IChainAdmin} from "./IChainAdmin.sol";
<<<<<<< HEAD
import {IAdmin} from "../state-transition/chain-interfaces/IAdmin.sol";
=======
import {IRestriction} from "./IRestriction.sol";
import { Call } from "./Common.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
>>>>>>> 5ee25ac0 (limit chain admin in power)

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The contract is designed to hold the `admin` role in ZKSync Chain (State Transition) contracts.
/// The owner of the contract can perform any external calls and also save the information needed for
/// the blockchain node to accept the protocol upgrade. Another role - `tokenMultiplierSetter` can be used in the contract
/// to change the base token gas price in the Chain contract.
contract ChainAdmin is IChainAdmin, Ownable2Step {
<<<<<<< HEAD
=======
    using EnumerableSet for EnumerableSet.AddressSet;

    modifier onlySelf {
        require(msg.sender == address(this), "Only self");
        _;
    }

    constructor(address _initialOwner) {
        // solhint-disable-next-line gas-custom-errors, reason-string
        require(_initialOwner != address(0), "Initial owner should be non zero address");
        _transferOwnership(_initialOwner);
    }

>>>>>>> 5ee25ac0 (limit chain admin in power)
    /// @notice Mapping of protocol versions to their expected upgrade timestamps.
    /// @dev Needed for the offchain node administration to know when to start building batches with the new protocol version.
    mapping(uint256 protocolVersion => uint256 upgradeTimestamp) public protocolVersionToUpgradeTimestamp;

<<<<<<< HEAD
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

    /// @notice Updates the address responsible for setting token multipliers on the Chain contract .
    /// @param _tokenMultiplierSetter The new address to be set as the token multiplier setter.
    function setTokenMultiplierSetter(address _tokenMultiplierSetter) external onlyOwner {
        emit NewTokenMultiplierSetter(tokenMultiplierSetter, _tokenMultiplierSetter);
        tokenMultiplierSetter = _tokenMultiplierSetter;
=======
    EnumerableSet.AddressSet internal activeRestrictions;    

    function getRestrictions() public view returns (address[] memory) {
        return activeRestrictions.values();
    }

    function isRestrictionActive(address restriction) external view returns (bool) {
        return activeRestrictions.contains(restriction);
    }

    function addRestriction(address restriction) external onlyOwner {
        activeRestrictions.add(restriction);
    }

    // Note that it is `onlySelf` because some restrictions may not allow to remove themselves
    function removeRestriction(address restriction) external onlySelf {
        activeRestrictions.remove(restriction);
>>>>>>> 5ee25ac0 (limit chain admin in power)
    }

    /// @notice Set the expected upgrade timestamp for a specific protocol version.
    /// @param _protocolVersion The ZKsync chain protocol version.
    /// @param _upgradeTimestamp The timestamp at which the chain node should expect the upgrade to happen.
    function setUpgradeTimestamp(uint256 _protocolVersion, uint256 _upgradeTimestamp) external onlyOwner {
        protocolVersionToUpgradeTimestamp[_protocolVersion] = _upgradeTimestamp;
        emit UpdateUpgradeTimestamp(_protocolVersion, _upgradeTimestamp);
    }

    /// @notice Execute multiple calls as part of contract administration.
    /// @param _calls Array of Call structures defining target, value, and data for each call.
    /// @param _requireSuccess If true, reverts transaction on any call failure.
    /// @dev Intended for batch processing of contract interactions, managing gas efficiency and atomicity of operations.
    function multicall(Call[] calldata _calls, bool _requireSuccess) external payable onlyOwner {
        require(_calls.length > 0, "No calls provided");
        for (uint256 i = 0; i < _calls.length; ++i) {
            require(_validateCall(_calls[i]), "Unallowed call");

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
    function _validateCall(Call calldata _call) internal view returns (bool) {
        address[] memory restrictions = getRestrictions();

        unchecked {
            for (uint256 i = 0; i < restrictions.length; i++) {
                IRestriction(restrictions[i]).validateCall(_call);
            }
        } 
    }
}
