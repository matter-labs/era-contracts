// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {BaseZkSyncUpgrade} from "./BaseZkSyncUpgrade.sol";
import {MAX_ALLOWED_MINOR_VERSION_DELTA} from "../common/Config.sol";
import {SemVer} from "../common/libraries/SemVer.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Interface to which all the upgrade implementations should adhere
abstract contract BaseZkSyncUpgradeGenesis is BaseZkSyncUpgrade {
    /// @notice Changes the protocol version
    /// @param _newProtocolVersion The new protocol version
    function _setNewProtocolVersion(
        uint256 _newProtocolVersion
    ) internal override returns (uint32 newMinorVersion, bool patchOnly) {
        uint256 previousProtocolVersion = s.protocolVersion;
        // IMPORTANT Genesis Upgrade difference: Note this is the only thing change > to >=
        require(
            _newProtocolVersion >= previousProtocolVersion,
            "New protocol version is not greater than the current one"
        );
        // slither-disable-next-line unused-return
        (uint32 previousMajorVersion, uint32 previousMinorVersion, ) = SemVer.unpackSemVer(
            SafeCast.toUint96(previousProtocolVersion)
        );
        require(previousMajorVersion == 0, "Implementation requires that the major version is 0 at all times");

        uint32 newMajorVersion;
        // slither-disable-next-line unused-return
        (newMajorVersion, newMinorVersion, ) = SemVer.unpackSemVer(SafeCast.toUint96(_newProtocolVersion));
        require(newMajorVersion == 0, "Major must always be 0");

        // Since `_newProtocolVersion > previousProtocolVersion`, and both old and new major version is 0,
        // the difference between minor versions is >= 0.
        uint256 minorDelta = newMinorVersion - previousMinorVersion;

        // IMPORTANT Genesis Upgrade difference: We never set patchOnly to `true` to allow to put a system upgrade transaction there.
        patchOnly = false;

        // While this is implicitly enforced by other checks above, we still double check just in case
        require(minorDelta <= MAX_ALLOWED_MINOR_VERSION_DELTA, "Too big protocol version difference");

        // If the minor version changes also, we need to ensure that the previous upgrade has been finalized.
        // In case the minor version does not change, we permit to keep the old upgrade transaction in the system, but it
        // must be ensured in the other parts of the upgrade that the is not overridden.
        if (!patchOnly) {
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
