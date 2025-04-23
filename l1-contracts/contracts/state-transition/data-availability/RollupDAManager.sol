// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ZeroAddress} from "../../common/L1ContractErrors.sol";

/// @title The RollupManager contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Responsible for determining which DA pairs are allowed to be used
/// for permanent rollups.
contract RollupDAManager is Ownable2Step {
    /// @dev Mapping to track the status (enabled/disabled) of each DAPair.
    mapping(address l1DAValidator => mapping(address l2DAValidator => bool)) public allowedDAPairs;

    /// @dev Emitted when a DAPair is added or updated.
    /// @param l1DAValidator Address of the L1 data availability validator.
    /// @param l2DAValidator Address of the L2 data availability validator.
    /// @param status Boolean representing the state of the DAPair.
    event DAPairUpdated(address indexed l1DAValidator, address indexed l2DAValidator, bool status);

    /// @dev Modifier to ensure addresses in DAPair are not zero addresses.
    /// @param l1DAValidator Address of the L1 data availability validator.
    /// @param l2DAValidator Address of the L2 data availability validator.
    modifier validAddresses(address l1DAValidator, address l2DAValidator) {
        if (l1DAValidator == address(0) || l2DAValidator == address(0)) {
            revert ZeroAddress();
        }
        _;
    }

    /// @dev Adds or updates a DAPair in the `allowedDAPairs` mapping. Only callable by the contract owner.
    ///
    /// Emits a {DAPairUpdated} event.
    ///
    /// @param _l1DAValidator Address of the L1 data availability validator.
    /// @param _l2DAValidator Address of the L2 data availability validator.
    /// @param _status Boolean representing whether the DAPair is active or not.
    ///
    /// Requirements:
    ///
    /// - The `l1DAValidator` and `l2DAValidator` must be valid addresses (non-zero).
    /// - Only the owner of the contract can call this function.
    function updateDAPair(
        address _l1DAValidator,
        address _l2DAValidator,
        bool _status
    ) external onlyOwner validAddresses(_l1DAValidator, _l2DAValidator) {
        allowedDAPairs[_l1DAValidator][_l2DAValidator] = _status;

        emit DAPairUpdated(_l1DAValidator, _l2DAValidator, _status);
    }

    /// @notice Returns whether the DA pair is allowed.
    ///
    /// @param _l1DAValidator Address of the L1 data availability validator.
    /// @param _l2DAValidator Address of the L2 data availability validator.
    /// @return bool indicating if the DA pair is allowed.
    function isPairAllowed(address _l1DAValidator, address _l2DAValidator) external view returns (bool) {
        return allowedDAPairs[_l1DAValidator][_l2DAValidator];
    }
}
