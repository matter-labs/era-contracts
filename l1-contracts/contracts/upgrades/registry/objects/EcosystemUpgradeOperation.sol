// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IEcosystemUpgradeOperation} from "./IEcosystemUpgradeOperation.sol";
import {OperationManifest} from "../RegistryTypes.sol";
import {ZeroAddress} from "../../../common/L1ContractErrors.sol";

/// @title EcosystemUpgradeOperation
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Storage-backed, write-once ecosystem upgrade operation. What it pins is the
///         PARTICIPATION of an upgrade — which registry and which transition — so
///         the coordinator's later stages can only ever name the operation governance prepared.
/// @dev Provenance of the referenced objects (codehash pins, edges) is the executors' business at
///      stage 0; this object checks only the shape a manifest must have to be one operation.
contract EcosystemUpgradeOperation is IEcosystemUpgradeOperation {
    /// @dev THE manifest, stored as its own ABI encoding — see {CTMRelease} for why the struct is
    ///      not transcribed into structured storage.
    bytes internal encodedManifest;

    /// @notice Pins the manifest. No state-mutating function exists on this contract.
    constructor(OperationManifest memory _manifest) {
        if (_manifest.transition == address(0)) {
            revert ZeroAddress();
        }
        encodedManifest = abi.encode(_manifest);
    }

    /// @inheritdoc IEcosystemUpgradeOperation
    function manifestHash() external view returns (bytes32) {
        return keccak256(encodedManifest);
    }

    /// @inheritdoc IEcosystemUpgradeOperation
    function getManifest() public view returns (OperationManifest memory) {
        return abi.decode(encodedManifest, (OperationManifest));
    }

    /// @inheritdoc IEcosystemUpgradeOperation
    function coreRegistry() external view returns (address) {
        return getManifest().coreRegistry;
    }

    /// @inheritdoc IEcosystemUpgradeOperation
    function transition() external view returns (address) {
        return getManifest().transition;
    }
}
