// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";

interface IDefaultUpgrade {
    function upgrade(ProposedUpgrade calldata _upgrade) external returns (bytes32);

    function upgradeInner(ProposedUpgrade calldata _upgrade) external returns (bytes32);

    /// @notice Registry-driven upgrade: the executor composes the `ProposedUpgrade` on-chain from
    ///         the pinned registry, so the committed cut carries only `(registry, timestamp)`.
    function upgradeFromTransition(address _transition) external returns (bytes32);
}
