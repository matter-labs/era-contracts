// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BytecodeUtils} from "../../utils/bytecode/BytecodeUtils.s.sol";

/// @title Build-artifact accessor for the codehash-PINNED registry objects.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice One source for both halves of a code pin: the creation code an object is DEPLOYED from
///         and the runtime codehash an executor PINS for it. `CTMUpgradeExecutor.TRANSITION_CODEHASH`
///         and `EcosystemUpgradeExecutor.CORE_REGISTRY_CODEHASH` are set once, at construction, and
///         reject every object that does not run exactly that code — so a pin taken from the build
///         artifact while the object is deployed from the SCRIPT's own compiled copy of the same
///         contract can brick the lifecycle: the two differ whenever the two compilations do (the
///         CBOR metadata records the compilation's remappings, which is enough).
/// @dev Both accessors read the same artifact JSON, so the deployed runtime code IS the code the
///      pin covers, by construction. The prepare scripts additionally re-check every object they
///      deploy against the live executor's pin, so a mismatch fails at prepare time.
library PinnedRegistryObject {
    /// @notice Creation code for `_contractName` in `_fileName`, from the build artifact.
    function creationCode(string memory _fileName, string memory _contractName) internal view returns (bytes memory) {
        return BytecodeUtils.readBytecodeL1(_fileName, _contractName);
    }

    /// @notice The `EXTCODEHASH` an executor must pin for `_contractName`.
    function codehash(string memory _fileName, string memory _contractName) internal view returns (bytes32) {
        return keccak256(BytecodeUtils.readDeployedBytecodeL1(_fileName, _contractName));
    }
}
