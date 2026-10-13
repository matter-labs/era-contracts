// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L1MessageRoot} from "../core/message-root/L1MessageRoot.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Test-only `L1MessageRoot` that can set `v31UpgradeChainBatchNumber`.
/// @dev Nothing in production writes it any more: chains recorded it during their own v31 upgrade, so a fresh
/// deployment keeps it at 0 for every chain. Tests of the `_noBatchFallback` path for pre-v31 batches set it here
/// instead of rewriting storage.
contract L1MessageRootDev is L1MessageRoot {
    constructor(address _bridgehub, address _chainAssetHandler) L1MessageRoot(_bridgehub, _chainAssetHandler) {}

    /// @dev For local testing only.
    function setV31UpgradeChainBatchNumberForTesting(uint256 _chainId, uint256 _batchNumber) external {
        v31UpgradeChainBatchNumber[_chainId] = _batchNumber;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}
