// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IEcosystemUpgradeOperation} from "./IEcosystemUpgradeOperation.sol";
import {OperationManifest, ProxyUpgradeRow} from "../RegistryTypes.sol";
import {CTM_CONTRACT_COUNT} from "../libraries/ContractIdentifiers.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {OperationChangesNothing, ZeroAddress} from "../../../common/L1ContractErrors.sol";

/// @title EcosystemUpgradeOperation
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Storage-backed, write-once ecosystem upgrade operation: the infrastructure changes of
///         one upgrade, the chain-version edge it may carry, and the delay before governance may
///         execute it. See {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Provenance of the referenced objects (codehash pins, edges) is the executors' business at
///      stage 0; this object checks only the shape a manifest must have to be one operation.
contract EcosystemUpgradeOperation is IEcosystemUpgradeOperation {
    /// @dev THE manifest, stored as its own ABI encoding — see {CTMRelease} for why the struct is
    ///      not transcribed into structured storage.
    bytes internal encodedManifest;

    /// @notice Pins the manifest. No state-mutating function exists on this contract.
    constructor(OperationManifest memory _manifest) {
        if (_manifest.timer == address(0)) {
            revert ZeroAddress();
        }
        ProxyUpgradeRow[] memory rows = ProxyUpgradeRowLib.toRows(_manifest.ctmInfrastructure, CTM_CONTRACT_COUNT);
        ProxyUpgradeRowLib.validateRows(rows);
        // An all-inert inventory is not a change: the container's presence must never make an
        // operation that upgrades nothing look like one that upgrades something.
        if (_manifest.coreTransition == address(0) && rows.length == 0 && _manifest.transition == address(0)) {
            revert OperationChangesNothing();
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
    function coreTransition() external view returns (address) {
        return getManifest().coreTransition;
    }

    /// @inheritdoc IEcosystemUpgradeOperation
    function ctmInfrastructureRows() external view returns (ProxyUpgradeRow[] memory) {
        return ProxyUpgradeRowLib.toRows(getManifest().ctmInfrastructure, CTM_CONTRACT_COUNT);
    }

    /// @inheritdoc IEcosystemUpgradeOperation
    function transition() external view returns (address) {
        return getManifest().transition;
    }

    /// @inheritdoc IEcosystemUpgradeOperation
    function timer() external view returns (address) {
        return getManifest().timer;
    }

    /// @inheritdoc IEcosystemUpgradeOperation
    /// @dev THE enumeration of what this operation names ITSELF: the timer and every
    ///      participating infrastructure row's implementation. The core transition and the
    ///      transition are objects with check surfaces of their own, driven by the domain
    ///      executors that hold them.
    function validate() external view {
        OperationManifest memory m = getManifest();
        ObjectAnchorLib.requireCode(m.timer);
        ProxyUpgradeRowLib.requireRowCode(ProxyUpgradeRowLib.toRows(m.ctmInfrastructure, CTM_CONTRACT_COUNT));
    }
}
