// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultChainUpgrade} from "../default-upgrade/DefaultChainUpgrade.s.sol";

/// @notice Per-chain upgrade script for the v32 (atomic interop) upgrade.
/// @dev v32 needs no per-chain extras: v31's token registration/migration was a one-off, and the
///      v32 upgrade is storage-compatible without migrations. The default flow (chain admin
///      calling `upgradeChainFromVersion` with the committed cut) is sufficient.
contract ChainUpgrade_v32 is DefaultChainUpgrade {}
