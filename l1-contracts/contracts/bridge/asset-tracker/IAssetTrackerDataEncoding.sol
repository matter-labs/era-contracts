// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {TokenBalanceMigrationData} from "../../common/Messaging.sol";

interface IAssetTrackerDataEncoding {
    function receiveMigrationOnL1(TokenBalanceMigrationData calldata _data) external;
}
