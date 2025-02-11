// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Gateway upgrade interface. Used for the protocol upgrade that introduces the Gateway.
 */
interface IGatewayUpgrade {
    /// @notice The upgrade function called from within this same contract
    /// @dev This is needed for memory -> calldata conversion of the _upgrade arg.
    /// @param _upgrade The upgrade to be executed.
    function upgradeExternal(ProposedUpgrade calldata _upgrade) external;
}
