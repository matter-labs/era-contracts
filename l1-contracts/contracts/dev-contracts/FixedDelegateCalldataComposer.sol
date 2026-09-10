// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICTMRelease} from "../upgrades/registry/objects/ICTMRelease.sol";
import {IL2DelegateCalldataComposer} from "../upgrades/registry/objects/IL2DelegateCalldataComposer.sol";

/// @notice Test-only composer that returns constructor-pinned calldata regardless of its inputs —
///         the harness's stand-in for a version-specific composer, so lifecycle tests can pin a
///         no-op delegate call without a real L2 migration behind it.
contract FixedDelegateCalldataComposer is IL2DelegateCalldataComposer {
    bytes internal fixedCalldata;

    constructor(bytes memory _fixedCalldata) {
        fixedCalldata = _fixedCalldata;
    }

    /// @inheritdoc IL2DelegateCalldataComposer
    function composeDelegateCalldata(ICTMRelease, address) external view returns (bytes memory) {
        return fixedCalldata;
    }
}
