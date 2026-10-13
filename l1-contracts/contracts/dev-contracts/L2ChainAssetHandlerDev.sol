// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2ChainAssetHandler} from "../core/chain-asset-handler/L2ChainAssetHandler.sol";

/// @notice Test-only variant of `L2ChainAssetHandler` for the Anvil multichain harness and foundry tests.
contract L2ChainAssetHandlerDev is L2ChainAssetHandler {
    /// @dev Re-enables chain migrations (disabled in production via `CHAIN_MIGRATIONS_ENABLED` in
    /// `Config.sol`) so tests keep exercising the migration machinery.
    function _getChainMigrationsEnabled() internal pure override returns (bool) {
        return true;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
