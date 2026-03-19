// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {
    GatewayToL1TokenBalanceMigrationData,
    InteropCallExecutedMessage,
    L1ToGatewayTokenBalanceMigrationData
} from "../../common/Messaging.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice The contract interface that is used for data encoding for the asset tracker related messages.
 */
interface IAssetTrackerDataEncoding {
    function receiveL1ToGatewayMigrationOnL1(L1ToGatewayTokenBalanceMigrationData calldata _data) external;

    function receiveGatewayToL1MigrationOnL1(GatewayToL1TokenBalanceMigrationData calldata _data) external;

    /// @notice Used as a function selector source for messages sent by InteropHandler to GWAssetTracker.
    /// @dev One message is sent per successfully executed interop call so GWAssetTracker can move
    /// balances from pendingInteropBalance to chainBalance.
    function receiveInteropCallExecuted(InteropCallExecutedMessage calldata _data) external;
}
