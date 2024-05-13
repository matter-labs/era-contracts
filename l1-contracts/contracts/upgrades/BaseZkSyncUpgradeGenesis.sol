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
    function _setNewProtocolVersion(uint256 _newProtocolVersion) internal override {
        uint256 previousProtocolVersion = s.protocolVersion;
        require(
            // IMPORTANT Genesis Upgrade difference: Note this is the only thing change > to >=
            _newProtocolVersion >= previousProtocolVersion,
            "New protocol version is not greater than the current one"
        );
        require(
            _newProtocolVersion - previousProtocolVersion <= MAX_ALLOWED_PROTOCOL_VERSION_DELTA,
            "Too big protocol version difference"
        );

        // If the previous upgrade had an L2 system upgrade transaction, we require that it is finalized.
        require(s.l2SystemContractsUpgradeTxHash == bytes32(0), "Previous upgrade has not been finalized");
        require(
            s.l2SystemContractsUpgradeBatchNumber == 0,
            "The batch number of the previous upgrade has not been cleaned"
        );

        s.protocolVersion = _newProtocolVersion;
        emit NewProtocolVersion(previousProtocolVersion, _newProtocolVersion);
    }
}
