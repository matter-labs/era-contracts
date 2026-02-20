// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {
    GatewayToL1TokenBalanceMigrationData,
    L1ToGatewayTokenBalanceMigrationData
} from "../../common/Messaging.sol";

interface IAssetTrackerDataEncoding {
    /// @notice Selector-only helper used for decoding L1->Gateway migration messages on L1.
    function receiveL1ToGatewayMigrationOnL1(L1ToGatewayTokenBalanceMigrationData calldata _data) external;

    /// @notice Selector-only helper used for decoding Gateway->L1 migration messages on L1.
    function receiveGatewayToL1MigrationOnL1(GatewayToL1TokenBalanceMigrationData calldata _data) external;
}
