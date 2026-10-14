// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IEcosystemUpgradeOperation} from "./IEcosystemUpgradeOperation.sol";
import {ICoreTransition} from "./ICoreTransition.sol";
import {ICTMTransition} from "./ICTMTransition.sol";
import {OperationManifest, ProxyUpgradeRow} from "../RegistryTypes.sol";
import {CTM_CONTRACT_COUNT} from "../libraries/ContractIdentifiers.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {OperationChangesNothing} from "../../../common/L1ContractErrors.sol";

/// @title EcosystemUpgradeOperation
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Storage-backed, write-once ecosystem upgrade operation: the infrastructure changes of
///         one upgrade and the chain-version edge it may carry. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev The constructor checks only the shape a manifest must have to be one operation; whether the
///      named objects are usable is {validate}'s job, and whether they are the reviewed ones is
///      governance's (see "Provenance and validation" in {docs/registry-driven-upgrades.md}).
contract EcosystemUpgradeOperation is IEcosystemUpgradeOperation {
    /// @dev THE manifest, stored as its own ABI encoding — see {CTMRelease} for why the struct is
    ///      not transcribed into structured storage.
    bytes internal encodedManifest;

    /// @notice Pins the manifest. No state-mutating function exists on this contract.
    constructor(OperationManifest memory _manifest) {
        ProxyUpgradeRow[] memory rows = ProxyUpgradeRowLib.toRows(_manifest.ctmInfrastructure, CTM_CONTRACT_COUNT);
        ProxyUpgradeRowLib.validateRows(rows);
        // An all-inert inventory is not a change: the container's presence must never make an
        // operation that upgrades nothing look like one that upgrades something.
        if (_manifest.coreTransition == address(0) && rows.length == 0 && _manifest.ctmTransition == address(0)) {
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
    function ctmTransition() external view returns (address) {
        return getManifest().ctmTransition;
    }

    /// @inheritdoc IEcosystemUpgradeOperation
    function validate() external view {
        OperationManifest memory m = getManifest();
        ProxyUpgradeRowLib.requireRowCode(ProxyUpgradeRowLib.toRows(m.ctmInfrastructure, CTM_CONTRACT_COUNT));
        if (m.coreTransition != address(0)) {
            ObjectAnchorLib.requireCode(m.coreTransition);
            ICoreTransition(m.coreTransition).validate();
        }
        if (m.ctmTransition != address(0)) {
            ObjectAnchorLib.requireCode(m.ctmTransition);
            ICTMTransition(m.ctmTransition).validate();
        }
    }
}
