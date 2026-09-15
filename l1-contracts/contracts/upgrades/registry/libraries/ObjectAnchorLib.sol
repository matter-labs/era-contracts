// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {RegistryCodehashMismatch, RegistryTargetHasNoCode} from "../../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The two code checks the registry model runs against live addresses: "there is a
///         contract here at all", and "this candidate runs the audited code of the object type
///         the caller already committed to".
/// @dev The second is an ANCHOR check, not a self-check: `_expectedCodehash` is state the caller
///      established EARLIER (the CTM's `releaseCodehash`, an executor's `TRANSITION_CODEHASH` /
///      `CORE_REGISTRY_CODEHASH` / `OPERATION_CODEHASH`), so it constrains what a later,
///      arbitrary input may be. A hash that arrived WITH the candidate would prove nothing —
///      see the codehash-pin section of {docs/registry-driven-upgrades.md}.
library ObjectAnchorLib {
    /// @notice Reverts unless `_target` is a deployed contract.
    function requireCode(address _target) internal view {
        if (_target.code.length == 0) {
            revert RegistryTargetHasNoCode(_target);
        }
    }

    /// @notice Reverts unless `_candidate` is deployed code whose `EXTCODEHASH` is the anchored
    ///         `_expectedCodehash`.
    /// @dev The code-length check is not redundant with the comparison: an anchor can never be
    ///      zero, but reporting "nothing is deployed here" separately from "the wrong contract is
    ///      deployed here" is what makes a misconfigured package diagnosable.
    function requireObjectType(address _candidate, bytes32 _expectedCodehash) internal view {
        requireCode(_candidate);
        bytes32 actualCodehash = _candidate.codehash;
        if (actualCodehash != _expectedCodehash) {
            revert RegistryCodehashMismatch(_candidate, _expectedCodehash, actualCodehash);
        }
    }
}
