// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {EcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/EcosystemUpgradeOperation.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {OperationManifest, ProxyUpgradeRow} from "contracts/upgrades/registry/RegistryTypes.sol";
import {CTM_CONTRACT_COUNT} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

/// @dev Builders for the write-once operations the coordinator's stages take. The timer is
///      operation state now, and a `GovernanceUpgradeTimer` starts exactly once, so every
///      operation gets its own — `_newOperationTimer` is the fixture's factory for a zero-delay
///      one bound to its coordinator.
abstract contract OperationFixtures {
    mapping(address transition => EcosystemUpgradeOperation operation) internal operationOf;

    /// @dev A fresh zero-delay timer bound to the fixture's coordinator, so stage 1 is admissible
    ///      in the block stage 0 ran in.
    function _newOperationTimer() internal virtual returns (address);

    function _cachedOperationFor(ICTMTransition _transition) internal returns (EcosystemUpgradeOperation operation) {
        operation = operationOf[address(_transition)];
        if (address(operation) == address(0)) {
            operation = _operationWithCore(_transition, address(0));
        }
    }

    /// @dev The operation over `_transition` carrying `_ctmInfrastructure`, cached so the stage
    ///      drivers keyed on the transition pick it up.
    function _operationWithInfrastructure(
        ICTMTransition _transition,
        ProxyUpgradeRow[] memory _ctmInfrastructure
    ) internal returns (EcosystemUpgradeOperation operation) {
        operation = _deployOperation(address(0), _ctmInfrastructure, address(_transition), _newOperationTimer());
        operationOf[address(_transition)] = operation;
    }

    function _operationWithCore(
        ICTMTransition _transition,
        address _coreTransition
    ) internal returns (EcosystemUpgradeOperation operation) {
        operation = _deployOperation(_coreTransition, address(_transition));
        operationOf[address(_transition)] = operation;
    }

    function _deployOperation(
        address _coreTransition,
        address _transition
    ) internal returns (EcosystemUpgradeOperation) {
        return _deployOperation(_coreTransition, _emptyInventory(), _transition, _newOperationTimer());
    }

    function _deployOperation(
        address _coreTransition,
        ProxyUpgradeRow[] memory _ctmInfrastructure,
        address _transition,
        address _timer
    ) internal returns (EcosystemUpgradeOperation) {
        return
            new EcosystemUpgradeOperation(
                OperationManifest({
                    coreTransition: _coreTransition,
                    ctmInfrastructure: _ctmInfrastructure,
                    transition: _transition,
                    timer: _timer
                })
            );
    }

    /// @dev The enum-indexed inventory with every slot explicitly "not upgraded".
    function _emptyInventory() internal pure returns (ProxyUpgradeRow[] memory) {
        return new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
    }
}
