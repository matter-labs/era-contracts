// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {RegistryCodehashMismatch, RegistryPinTargetHasNoCode} from "../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice THE codehash-pin check, shared by every write-once registry object. A pin is valid
///         only if the target actually CARRIES CODE and its `EXTCODEHASH` equals the pinned
///         value — comparing hashes alone would accept an undeployed address pinned to zero, or
///         a codeless account pinned to the empty-code hash, silently pinning "no code" as a
///         verified implementation.
library CodehashPinLib {
    /// @notice Reverts unless `_target` is deployed code whose `EXTCODEHASH` is `_expectedCodehash`.
    function requirePin(address _target, bytes32 _expectedCodehash) internal view {
        if (_target.code.length == 0) {
            revert RegistryPinTargetHasNoCode(_target);
        }
        bytes32 actualCodehash = _target.codehash;
        if (actualCodehash != _expectedCodehash) {
            revert RegistryCodehashMismatch(_target, _expectedCodehash, actualCodehash);
        }
    }

    /// @notice Non-reverting variant for `verifyAll()` tooling reads.
    function pinHolds(address _target, bytes32 _expectedCodehash) internal view returns (bool) {
        return _target.code.length != 0 && _target.codehash == _expectedCodehash;
    }
}
