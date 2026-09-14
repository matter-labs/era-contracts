// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {EcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/EcosystemUpgradeOperation.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {CTMLeg, OperationManifest} from "contracts/upgrades/registry/RegistryTypes.sol";

/// @notice Shared operation builders of the registry suites: the one-leg operation a single-CTM
///         hop rides, cached per transition so the three stages name the same object, and the
///         raw builder the multi-CTM suite composes legs with.
abstract contract OperationFixtures {
    /// @dev One operation per transition, deployed on first use.
    mapping(address transition => EcosystemUpgradeOperation operation) internal operationOf;

    /// @dev The one-leg operation over `_transition` on `_executor`, with no ecosystem leg —
    ///      unless a suite registered one for this transition with `_operationWithCore` first.
    function _operationFor(
        ICTMTransition _transition,
        address _executor
    ) internal returns (EcosystemUpgradeOperation operation) {
        operation = operationOf[address(_transition)];
        if (address(operation) == address(0)) {
            operation = _operationWithCore(_transition, _executor, address(0));
        }
    }

    /// @dev The one-leg operation over `_transition` on `_executor` whose ecosystem leg is
    ///      `_coreRegistry`; replaces whatever the suite had cached for the transition.
    function _operationWithCore(
        ICTMTransition _transition,
        address _executor,
        address _coreRegistry
    ) internal returns (EcosystemUpgradeOperation operation) {
        CTMLeg[] memory legs = new CTMLeg[](1);
        legs[0] = CTMLeg({executor: _executor, transition: address(_transition)});
        operation = _deployOperation(_coreRegistry, legs);
        operationOf[address(_transition)] = operation;
    }

    function _deployOperation(
        address _coreRegistry,
        CTMLeg[] memory _legs
    ) internal returns (EcosystemUpgradeOperation) {
        return new EcosystemUpgradeOperation(OperationManifest({coreRegistry: _coreRegistry, legs: _legs}));
    }
}
