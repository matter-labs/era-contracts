// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {RegistryTargetHasNoCode} from "../../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The one code check the registry model runs against live addresses: "there is a
///         contract here at all".
/// @dev Deliberately the only one: a runtime codehash cannot show that the audited constructor
///      produced an object, so object trust is governance's approval of the exact deployed
///      objects, verified off-chain — see "Provenance and validation" in
///      {docs/registry-driven-upgrades.md}.
library ObjectAnchorLib {
    /// @notice Reverts unless `_target` is a deployed contract.
    /// @dev Not defensive bookkeeping: a call to a codeless address SUCCEEDS silently, and a
    ///      codeless delegatecall target turns a chain's upgrade into a no-op that reports
    ///      success. This is an execution precondition, and it stays on every path that commits
    ///      or applies an object.
    function requireCode(address _target) internal view {
        if (_target.code.length == 0) {
            revert RegistryTargetHasNoCode(_target);
        }
    }
}
