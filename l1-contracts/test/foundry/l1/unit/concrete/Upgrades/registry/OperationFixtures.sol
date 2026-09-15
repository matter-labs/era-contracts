// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
import {EcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/EcosystemUpgradeOperation.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {OperationManifest} from "contracts/upgrades/registry/RegistryTypes.sol";
abstract contract OperationFixtures {
    mapping(address transition => EcosystemUpgradeOperation operation) internal operationOf;
    function _cachedOperationFor(ICTMTransition _transition) internal returns (EcosystemUpgradeOperation operation) {
        operation = operationOf[address(_transition)];
        if (address(operation) == address(0)) {
            operation = _operationWithCore(_transition, address(0));
        }
    }
    function _operationWithCore(
        ICTMTransition _transition,
        address _coreRegistry
    ) internal returns (EcosystemUpgradeOperation operation) {
        operation = _deployOperation(_coreRegistry, address(_transition));
        operationOf[address(_transition)] = operation;
    }
    function _deployOperation(address _coreRegistry, address _transition) internal returns (EcosystemUpgradeOperation) {
        return new EcosystemUpgradeOperation(OperationManifest({coreRegistry: _coreRegistry, transition: _transition}));
    }
}
