// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ZeroAddress} from "../../common/L1ContractErrors.sol";
import {L2DACommitmentScheme} from "../../common/Config.sol";

/// @title The RollupManager contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Responsible for determining which DA pairs are allowed to be used
/// for permanent rollups.
contract RollupDAManager is Ownable2Step {
    /// @dev Mapping to track the status (enabled/disabled) of each DAPair. TODO
    mapping(address l1DAValidator => mapping(address l2DAValidator => bool)) public _DEPRECATED_allowedDAPairs;
    /// @dev Mapping to track the status (enabled/disabled) of each DAPair.
    mapping(address l1DAValidator => mapping(L2DACommitmentScheme => bool)) public allowedDAConfigurations;

    /// @dev Emitted when a DAPair is added or updated.
    /// @param l1DAValidator Address of the L1 data availability validator.
    /// @param l2DACommitmentScheme TODO
    /// @param status Boolean representing the state of the DAPair.
    event DAPairUpdated(address indexed l1DAValidator, L2DACommitmentScheme indexed l2DACommitmentScheme, bool status);

    /// @dev Modifier to ensure address in DAPair is not zero address.
    /// @param l1DAValidator Address of the L1 data availability validator.
    modifier validAddress(address l1DAValidator) {
        if (l1DAValidator == address(0)) {
            revert ZeroAddress();
        }
        _;
    }

    /// @dev Adds or updates a DAPair in the `allowedDAConfigurations` mapping. Only callable by the contract owner.
    ///
    /// Emits a {DAPairUpdated} event.
    ///
    /// @param _l1DAValidator Address of the L1 data availability validator.
    /// @param _l2DACommitmentScheme TODO
    /// @param _status Boolean representing whether the DAPair is active or not.
    ///
    /// Requirements:
    ///
    /// - The `l1DAValidator` must be valid address (non-zero).
    /// - Only the owner of the contract can call this function.
    function updateDAPair(
        address _l1DAValidator,
        L2DACommitmentScheme _l2DACommitmentScheme,
        bool _status
    ) external onlyOwner validAddress(_l1DAValidator) {
        allowedDAConfigurations[_l1DAValidator][_l2DACommitmentScheme] = _status;

        emit DAPairUpdated(_l1DAValidator, _l2DACommitmentScheme, _status);
    }

    /// @notice Returns whether the DA pair is allowed.
    ///
    /// @param _l1DAValidator Address of the L1 data availability validator.
    /// @param _l2DACommitmentScheme TODO
    /// @return bool indicating if the DA pair is allowed.
    function isPairAllowed(
        address _l1DAValidator,
        L2DACommitmentScheme _l2DACommitmentScheme
    ) external view returns (bool) {
        return allowedDAConfigurations[_l1DAValidator][_l2DACommitmentScheme];
    }
}
