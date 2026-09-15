// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {Call} from "contracts/governance/Common.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {IEcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/IEcosystemUpgradeOperation.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {OperationManifest, ProxyUpgradeRow} from "contracts/upgrades/registry/RegistryTypes.sol";
import {CTM_CONTRACT_COUNT} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

import {Create2FactoryUtils} from "../utils/deploy/Create2FactoryUtils.s.sol";
import {BytecodeUtils} from "../utils/bytecode/BytecodeUtils.s.sol";
import {ComposeOperationParams} from "./default-upgrade/UpgradeParams.sol";

/// @notice The compose step of a registry-driven upgrade, run once every prepare has finished:
///         deploys the write-once `EcosystemUpgradeOperation` over the core prepare's registry and
///         the CTM prepare's infrastructure rows, transition and timer, checks it against the live
///         coordinator
///         and executors, and emits the upgrade's three governance calls —
///         `EcosystemUpgradeExecutor.stage0/1/2(operation)`. Nothing here is authored: the
///         operation is the association of objects the prepares already deployed. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Rides the CREATE2 factory like every prepare deployment: the Safe bundle replays factory
///      transactions only, so a plain CREATE would leave the stage calls pointing at a codeless
///      address on the real chain.
contract ComposeUpgradeOperation is Script, Create2FactoryUtils {
    /// @notice The operation this run deployed.
    address public operation;

    function compose(ComposeOperationParams memory _params) public {
        setCreate2Salt(_params.create2FactorySalt);
        EcosystemUpgradeExecutor coordinator = EcosystemUpgradeExecutor(payable(_params.coordinator));
        require(address(coordinator).code.length != 0, "coordinator has no code");
        ProxyUpgradeRow[] memory ctmInfrastructure = _params.ctmInfrastructure.length == 0
            ? new ProxyUpgradeRow[](CTM_CONTRACT_COUNT)
            : abi.decode(_params.ctmInfrastructure, (ProxyUpgradeRow[]));
        require(ctmInfrastructure.length == CTM_CONTRACT_COUNT, "the CTM inventory is not the enum's length");

        // Every check the coordinator's stage 0 makes, evaluated now: a drifted binding or pin
        // must fail here, not with the whole upgrade already reviewed and scheduled.
        if (_params.coreRegistry != address(0)) {
            CoreUpgradeExecutor coreExecutor = coordinator.CORE_EXECUTOR();
            require(coreExecutor.coordinator() == address(coordinator), "core executor: wrong coordinator");
            require(
                _params.coreRegistry.codehash == coreExecutor.CORE_REGISTRY_CODEHASH(),
                "core registry: not the code the core executor pins"
            );
        }
        CTMUpgradeExecutor executor = CTMUpgradeExecutor(payable(address(coordinator.ctmExecutor())));
        require(address(executor) != address(0), "coordinator has no CTM executor");
        require(executor.coordinator() == address(coordinator), "CTM executor: wrong coordinator");
        if (_params.transition != address(0)) {
            require(
                _params.transition.codehash == executor.TRANSITION_CODEHASH(),
                "transition: not the code its executor pins"
            );
            ICTMTransition(_params.transition).validate();
        }
        require(
            GovernanceUpgradeTimer(_params.timer).TIMER_GOVERNANCE() == address(coordinator),
            "operation timer: not bound to the coordinator"
        );

        // From the build ARTIFACT, which is also where the coordinator's `OPERATION_CODEHASH` came
        // from — see {BytecodeUtils.getDeployedBytecodeHash}.
        operation = deployViaCreate2AndNotify(
            BytecodeUtils.readBytecodeL1("EcosystemUpgradeOperation.sol", "EcosystemUpgradeOperation"),
            abi.encode(
                OperationManifest({
                    coreRegistry: _params.coreRegistry,
                    ctmInfrastructure: ctmInfrastructure,
                    transition: _params.transition,
                    timer: _params.timer
                })
            ),
            "EcosystemUpgradeOperation"
        );
        require(
            operation.codehash == coordinator.OPERATION_CODEHASH(),
            "the deployed operation does not run the code the coordinator pins"
        );
        console.log("Operation manifest hash:", vm.toString(IEcosystemUpgradeOperation(operation).manifestHash()));

        _saveOutput(_params.outputPath, address(coordinator));
    }

    /// @notice The three governance calls of the upgrade, one per stage, all on the coordinator.
    function stageCalls(
        address _coordinator
    ) public view returns (Call[] memory stage0, Call[] memory stage1, Call[] memory stage2) {
        IEcosystemUpgradeOperation op = IEcosystemUpgradeOperation(operation);
        stage0 = _single(_coordinator, abi.encodeCall(EcosystemUpgradeExecutor.stage0, (op)));
        stage1 = _single(_coordinator, abi.encodeCall(EcosystemUpgradeExecutor.stage1, (op)));
        stage2 = _single(_coordinator, abi.encodeCall(EcosystemUpgradeExecutor.stage2, (op)));
    }

    function _single(address _target, bytes memory _data) private pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({target: _target, value: 0, data: _data});
    }

    /// @dev Same sections the prepares write, so the merge reads all outputs alike: `[registry]`
    ///      names the objects, `[governance_calls]` carries the stage bundles, and the empty
    ///      `external_actions` list (see {ExternalActionsLib.serialize} for an entry's shape)
    ///      states that nothing here is a declared action — the merge holds the compose step to
    ///      that, and to emitting the three lifecycle calls and nothing else.
    function _saveOutput(string memory _outputPath, address _coordinator) internal {
        (Call[] memory stage0, Call[] memory stage1, Call[] memory stage2) = stageCalls(_coordinator);
        vm.serializeAddress("registry", "operation_addr", operation);
        string memory registry = vm.serializeAddress("registry", "coordinator_addr", _coordinator);
        vm.serializeBytes("governance_calls", "stage0_calls", abi.encode(stage0));
        vm.serializeBytes("governance_calls", "stage1_calls", abi.encode(stage1));
        string memory governanceCalls = vm.serializeBytes("governance_calls", "stage2_calls", abi.encode(stage2));
        vm.serializeString("root", "external_actions", new string[](0));
        vm.serializeString("root", "registry", registry);
        string memory toml = vm.serializeString("root", "governance_calls", governanceCalls);
        // Like the prepares, `_outputPath` is relative to the project root with a leading slash.
        vm.writeToml(toml, string.concat(vm.projectRoot(), _outputPath));
    }
}
