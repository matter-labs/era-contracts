// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IEcosystemUpgradeOperation} from "../objects/IEcosystemUpgradeOperation.sol";
import {ICTMUpgradeExecutor} from "./ICTMUpgradeExecutor.sol";
import {IEcosystemUpgradeExecutor} from "./IEcosystemUpgradeExecutor.sol";
import {CoreUpgradeExecutor} from "./CoreUpgradeExecutor.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {
    ExecutorCoordinatorMismatch,
    CoordinatorCTMMismatch,
    OperationManifestChanged,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {OperationManifest} from "../RegistryTypes.sol";

/// @title EcosystemUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The coordinator of ecosystem upgrades. It owns no proxy administration: it executes an
///         operation by driving the domain executors (`CoreUpgradeExecutor` and one bound
///         `CTMUpgradeExecutor`), which perform the narrow operations on the authority they hold.
///         See {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Fixed logic, no generic delegatecall. `execute` takes the write-once
///      `EcosystemUpgradeOperation` governance approved; no caller-supplied calldata enters it.
///      This contract is the operation's only reader: it reads `getManifest()` once, holds it to
///      `manifestHash()`, and hands that manifest to the domain executors.
contract EcosystemUpgradeExecutor is UpgradeExecutorBase, IEcosystemUpgradeExecutor {
    using ObjectAnchorLib for address;

    /// @notice The executor of the ecosystem leg. Immutable: replacing it means replacing the
    ///         coordinator, which each domain does explicitly through its `setCoordinator`.
    CoreUpgradeExecutor public immutable CORE_EXECUTOR;

    /// @inheritdoc IEcosystemUpgradeExecutor
    ICTMUpgradeExecutor public ctmExecutor;

    constructor(address _initialOwner, CoreUpgradeExecutor _coreExecutor) UpgradeExecutorBase(_initialOwner) {
        if (address(_coreExecutor) == address(0)) {
            revert ZeroAddress();
        }
        CORE_EXECUTOR = _coreExecutor;
    }

    /// @inheritdoc IEcosystemUpgradeExecutor
    function setCTMExecutor(ICTMUpgradeExecutor _executor) external onlyOwner {
        if (address(_executor) == address(0)) {
            revert ZeroAddress();
        }
        ObjectAnchorLib.requireCode(address(_executor));
        address boundCoordinator = _executor.coordinator();
        if (boundCoordinator != address(this)) {
            revert ExecutorCoordinatorMismatch(address(this), boundCoordinator);
        }
        address nextCTM = address(_executor.CHAIN_TYPE_MANAGER());
        if (nextCTM == address(0)) {
            revert ZeroAddress();
        }
        if (address(ctmExecutor) != address(0)) {
            address currentCTM = address(ctmExecutor.CHAIN_TYPE_MANAGER());
            if (nextCTM != currentCTM) {
                revert CoordinatorCTMMismatch(currentCTM, nextCTM);
            }
        }
        emit CTMExecutorChanged(address(ctmExecutor), address(_executor));
        ctmExecutor = _executor;
    }

    /// @inheritdoc IEcosystemUpgradeExecutor
    function execute(IEcosystemUpgradeOperation _operation) external onlyOwner {
        ICTMUpgradeExecutor boundCTMExecutor = ctmExecutor;
        if (address(boundCTMExecutor) == address(0)) {
            revert ZeroAddress();
        }
        address(_operation).requireCode();
        _operation.validate();
        OperationManifest memory m = _operation.getManifest();
        bytes32 committed = _operation.manifestHash();
        bytes32 served = keccak256(abi.encode(m));
        if (served != committed) {
            revert OperationManifestChanged(committed, served);
        }
        if (m.coreTransition != address(0)) {
            CORE_EXECUTOR.applyOperation(m);
        }
        boundCTMExecutor.applyOperation(m);
        emit OperationExecuted(address(_operation));
    }
}
