// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {RegistryTargetHasNoCode} from "../../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The one code check the registry model runs against live addresses: "there is a
///         contract here at all".
/// @dev There used to be a second — a runtime-`EXTCODEHASH` comparison against a pinned
///      expectation, one per object type. It was removed because it answers a strictly weaker
///      question than it appeared to: creation code can write arbitrary storage and then return
///      the canonical runtime bytecode, so an object that PASSES such a check can still serve
///      state the audited constructor would never have produced. Object trust is established by
///      governance reviewing the exact deployed objects, with `protocol-ops ecosystem
///      verify-bootstrap` re-deriving each object's address from the reviewed creation code and
///      the manifest it serves — see "Provenance and validation" in
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
