// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";

interface IGatewayUpgrade {
    function upgradeExternal(ProposedUpgrade calldata _upgrade) external returns (bytes32);
}
