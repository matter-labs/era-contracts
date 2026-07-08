// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {L2InteropHandler} from "../interop/interop-handler/L2InteropHandler.sol";

/// @title InteropHandler (compatibility alias)
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev The L2 interop handler system contract was renamed to `L2InteropHandler`, but the zksync-era
/// bootloader test infrastructure (pinned via `system-contracts/bootloader/test_infra`) still loads its
/// bytecode from `zkout/InteropHandler.sol/InteropHandler.json` by the old name. This empty subclass
/// produces an identically-behaving artifact under that name.
/// TODO: remove once zksync-era's contract loader is updated to `L2InteropHandler`.
// solhint-disable-next-line no-empty-blocks
contract InteropHandler is L2InteropHandler {}
