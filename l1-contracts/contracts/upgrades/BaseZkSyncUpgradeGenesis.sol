// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {MAX_ALLOWED_PROTOCOL_VERSION_DELTA} from "../common/Config.sol";
import {BaseZkSyncUpgrade} from "./BaseZkSyncUpgrade.sol";
import {ProtocolVersionShouldBeGreater, ProtocolVersionDeltaTooLarge, PreviousUpgradeNotFinalized, PreviousUpgradeBatchNotCleared} from "./ZkSyncUpgradeErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Interface to which all the upgrade implementations should adhere
abstract contract BaseZkSyncUpgradeGenesis is BaseZkSyncUpgrade {
    /// @notice Changes the protocol version
    /// @param _newProtocolVersion The new protocol version
    function _setNewProtocolVersion(uint256 _newProtocolVersion) internal override {
        uint256 previousProtocolVersion = s.protocolVersion;
        if (
            // IMPORTANT Genesis Upgrade difference: Note this is the only thing change > to >=
            _newProtocolVersion < previousProtocolVersion
        ) {
            revert ProtocolVersionShouldBeGreater(previousProtocolVersion, _newProtocolVersion);
        }
        uint256 protocolDiff = _newProtocolVersion - previousProtocolVersion;
        if (protocolDiff > MAX_ALLOWED_PROTOCOL_VERSION_DELTA) {
            revert ProtocolVersionDeltaTooLarge(protocolDiff, MAX_ALLOWED_PROTOCOL_VERSION_DELTA);
        }

        // If the previous upgrade had an L2 system upgrade transaction, we require that it is finalized.
        if (s.l2SystemContractsUpgradeTxHash != bytes32(0)) {
            revert PreviousUpgradeNotFinalized();
        }

        if (s.l2SystemContractsUpgradeBatchNumber != 0) {
            revert PreviousUpgradeBatchNotCleared();
        }

        s.protocolVersion = _newProtocolVersion;
        emit NewProtocolVersion(previousProtocolVersion, _newProtocolVersion);
    }
}
