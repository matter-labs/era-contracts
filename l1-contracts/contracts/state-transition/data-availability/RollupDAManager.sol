// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ZeroAddress, InvalidL2DACommitmentScheme} from "../../common/L1ContractErrors.sol";
import {L2DACommitmentScheme} from "../../common/Config.sol";

/// @title The RollupManager contract
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Responsible for determining which DA configurations (DAPairs) are allowed to be used
/// for permanent rollups.
contract RollupDAManager is Ownable2Step {
    /// @dev Mapping to track the status (enabled/disabled) of each DAPair.
    mapping(address l1DAValidator => mapping(L2DACommitmentScheme l2DACommitmentScheme => bool))
        public isAllowedDAConfiguration;

    /// @dev Emitted when a DAPair is added or updated.
    /// @param l1DAValidator Address of the L1 data availability validator.
    /// @param l2DACommitmentScheme The scheme of L2 DA commitment. Different L1 validators may use different schemes.
    /// @param status Boolean representing the state of the DAPair.
    event DAPairUpdated(address indexed l1DAValidator, L2DACommitmentScheme indexed l2DACommitmentScheme, bool status);

    /// @dev Modifier to ensure address in DAPair is not zero address and l2DACommitmentScheme is not NONE.
    /// @param l1DAValidator Address of the L1 data availability validator.
    /// @param l2DACommitmentScheme The scheme of L2 DA commitment. Different L1 validators may use different schemes.
    modifier validDAConfiguration(address l1DAValidator, L2DACommitmentScheme l2DACommitmentScheme) {
        if (l1DAValidator == address(0)) {
            revert ZeroAddress();
        }

        if (l2DACommitmentScheme == L2DACommitmentScheme.NONE) {
            revert InvalidL2DACommitmentScheme(uint8(l2DACommitmentScheme));
        }
        _;
    }

    /// @dev Adds or updates a DAPair in the `isAllowedDAConfiguration` mapping. Only callable by the contract owner.
    ///
    /// Emits a {DAPairUpdated} event.
    ///
    /// @param _l1DAValidator Address of the L1 data availability validator.
    /// @param _l2DACommitmentScheme The scheme of L2 DA commitment. Different L1 validators may use different schemes.
    /// @param _status Boolean representing whether the DAPair is active or not.
    ///
    /// Requirements:
    ///
    /// - The `l1DAValidator` must be valid address (non-zero).
    /// - The `l2DACommitmentScheme` must be valid scheme (not NONE).
    /// - Only the owner of the contract can call this function.
    function updateDAPair(
        address _l1DAValidator,
        L2DACommitmentScheme _l2DACommitmentScheme,
        bool _status
    ) external onlyOwner validDAConfiguration(_l1DAValidator, _l2DACommitmentScheme) {
        isAllowedDAConfiguration[_l1DAValidator][_l2DACommitmentScheme] = _status;

        emit DAPairUpdated(_l1DAValidator, _l2DACommitmentScheme, _status);
    }

    /// @notice Returns whether the DA pair is allowed.
    ///
    /// @param _l1DAValidator Address of the L1 data availability validator.
    /// @param _l2DACommitmentScheme The scheme of L2 DA commitment. Different L1 validators may use different schemes.
    /// @return bool indicating if the DA pair is allowed.
    function isPairAllowed(
        address _l1DAValidator,
        L2DACommitmentScheme _l2DACommitmentScheme
    ) external view returns (bool) {
        return isAllowedDAConfiguration[_l1DAValidator][_l2DACommitmentScheme];
    }
}
