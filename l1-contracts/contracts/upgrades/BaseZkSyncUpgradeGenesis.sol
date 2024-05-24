// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {MAX_ALLOWED_PROTOCOL_VERSION_DELTA} from "../common/Config.sol";
import {BaseZkSyncUpgrade} from "./BaseZkSyncUpgrade.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Interface to which all the upgrade implementations should adhere
abstract contract BaseZkSyncUpgradeGenesis is BaseZkSyncUpgrade {
    /// @notice Changes the protocol version
    /// @param _newProtocolVersion The new protocol version
    function _setNewProtocolVersion(uint256 _newProtocolVersion) internal override returns (bool patchOnly) {
        uint256 previousProtocolVersion = s.protocolVersion;
        // IMPORTANT Genesis Upgrade difference: Note this is the only thing change > to >=
        require(
            _newProtocolVersion >= previousProtocolVersion,
            "New protocol version is not greater than the current one"
        );

        (uint32 newMajor,,) = SemVer.unpackSemVer(_newProtocolVersion);
        require(newMajor == 0, "Only major version of 0 is supported");

        (uint32 majorDelta, uint32 minorDelta, uint32 patchDelta) = SemVer.unpackSemVer(_newProtocolVersion - previousProtocolVersion);

        if (minorDelta == 0) {
            patchOnly = true;
        }

        // While this is implicitly enforced by other checks above, we still double check just in case
        require(majorDelta == 0, "Major version change is not allowed");
        require(minorDelta <= MAX_ALLOWED_MINOR_VERSION_DELTA, "Too big protocol version difference");

        // If the minor version changes also, we need to ensure that the previous upgrade has been finalized.
        // In case the minor version does not change, we permit to keep the old upgrade transaction in the system, but it 
        // must be ensured in the other parts of the upgrade that the is not overriden. 
        if(!patchOnly) {
            // If the previous upgrade had an L2 system upgrade transaction, we require that it is finalized.
            // Note it is important to keep this check, as otherwise hyperchains might skip upgrades by overwriting
            require(s.l2SystemContractsUpgradeTxHash == bytes32(0), "Previous upgrade has not been finalized");
            require(
                s.l2SystemContractsUpgradeBatchNumber == 0,
                "The batch number of the previous upgrade has not been cleaned"
            );
        }

        s.protocolVersion = _newProtocolVersion;
        emit NewProtocolVersion(previousProtocolVersion, _newProtocolVersion);
    }
}
