// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IEcosystemUpgradeOperation} from "./IEcosystemUpgradeOperation.sol";
import {ICTMUpgradeExecutor} from "../executors/ICTMUpgradeExecutor.sol";
import {CTMLeg, OperationManifest} from "../RegistryTypes.sol";
import {DuplicateOperationLeg, EmptyOperation, ZeroAddress} from "../../../common/L1ContractErrors.sol";

/// @title EcosystemUpgradeOperation
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Storage-backed, write-once ecosystem upgrade operation. What it pins is the
///         PARTICIPATION of an upgrade — which registry and which transition on which CTM — so
///         the coordinator's later stages can only ever name the operation governance prepared.
/// @dev Provenance of the legs' objects (codehash pins, edges) is the executors' business at
///      stage 0; this object checks only the shape a manifest must have to be one operation.
contract EcosystemUpgradeOperation is IEcosystemUpgradeOperation {
    /// @dev THE manifest, stored as its own ABI encoding — see {CTMRelease} for why the struct is
    ///      not transcribed into structured storage.
    bytes internal encodedManifest;

    /// @notice Pins the manifest. No state-mutating function exists on this contract.
    constructor(OperationManifest memory _manifest) {
        uint256 legCount = _manifest.legs.length;
        // A core-only change rides a schedule-only transition on one CTM; an operation with no
        // CTM leg would bypass every CTM-domain pause and timer.
        if (legCount == 0) {
            revert EmptyOperation();
        }
        address[] memory ctms = new address[](legCount);
        for (uint256 i = 0; i < legCount; ++i) {
            CTMLeg memory leg = _manifest.legs[i];
            if (leg.executor == address(0) || leg.transition == address(0)) {
                revert ZeroAddress();
            }
            address ctm = address(ICTMUpgradeExecutor(leg.executor).CHAIN_TYPE_MANAGER());
            for (uint256 j = 0; j < i; ++j) {
                if (ctms[j] == ctm) {
                    revert DuplicateOperationLeg(ctm);
                }
            }
            ctms[i] = ctm;
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
    function legs() external view returns (CTMLeg[] memory) {
        return getManifest().legs;
    }
}
