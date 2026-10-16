// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

/// @dev The trimmed per-CTM output the memory-trimmed upgrade harnesses (`_EcosystemUpgradeForTests_v36*.sol`)
///      write instead of the full prepare output, so accumulated `vm.serialize*` JSON does not blow
///      forge's EVM memory.
library TrimmedUpgradeOutput {
    struct Registry {
        address ctmTransition;
        address ctmUpgradeExecutor;
        address ctmRelease;
        address bootstrapMigration;
        address operation;
        address coordinator;
    }

    /// @dev What `protocol-ops ecosystem verify-package` reads beside the registry block: the
    ///      salt the run deployed under, the CTM and its ProxyAdmin the executor's bindings are
    ///      held against, and the force-deployments blob the release pins.
    struct Reviewed {
        bytes32 create2FactorySalt;
        address chainTypeManagerProxy;
        address transparentProxyAdmin;
        bytes forceDeploymentsData;
    }

    /// @param _eip7702Checker The CTM domain's EIP-7702 checker, carried forward exactly as a
    ///        production prepare's output carries it: the MailboxFacet pins it as an immutable and
    ///        nothing on-chain exposes it, so the NEXT upgrade's input has to name it or it deploys
    ///        a fresh one and drags a Mailbox replacement behind it.
    function write(
        Vm _vm,
        string memory _outputPath,
        bytes memory _upgradeCutData,
        address _defaultUpgrade,
        address _eip7702Checker,
        Registry memory _registry,
        Reviewed memory _reviewed
    ) internal {
        _vm.serializeAddress("state_transition", "eip7702_checker_addr", _eip7702Checker);
        _vm.serializeAddress("state_transition", "chain_type_manager_proxy", _reviewed.chainTypeManagerProxy);
        string memory stateTransition = _vm.serializeAddress(
            "state_transition",
            "default_upgrade_addr",
            _defaultUpgrade
        );
        _vm.serializeAddress("registry", "ctm_transition_addr", _registry.ctmTransition);
        _vm.serializeAddress("registry", "ctm_release_addr", _registry.ctmRelease);
        // The trimmed writer replaces the heavy `state_transition` section, NOT the registry
        // block: every object the production output names has to survive here too, or a package
        // verified from the harness is not the shape a package verified in production is.
        _vm.serializeAddress("registry", "bootstrap_migration_addr", _registry.bootstrapMigration);
        _vm.serializeAddress("registry", "ctm_upgrade_executor_addr", _registry.ctmUpgradeExecutor);
        // The merge derives this upgrade's `execute` call from exactly these two addresses, so a
        // trimmed output that omitted them would produce a package with no executor call at all.
        _vm.serializeAddress("registry", "coordinator_addr", _registry.coordinator);
        string memory registry = _vm.serializeAddress("registry", "operation_addr", _registry.operation);
        string memory deployedAddresses = _vm.serializeAddress(
            "deployed_addresses",
            "transparent_proxy_admin",
            _reviewed.transparentProxyAdmin
        );
        string memory contractsConfig = _vm.serializeBytes(
            "contracts_config",
            "force_deployments_data",
            _reviewed.forceDeploymentsData
        );
        _vm.serializeBytes32("root", "create2_factory_salt", _reviewed.create2FactorySalt);
        _vm.serializeString("root", "deployed_addresses", deployedAddresses);
        _vm.serializeString("root", "contracts_config", contractsConfig);
        _vm.serializeBytes("root", "chain_upgrade_diamond_cut", _upgradeCutData);
        _vm.serializeString("root", "registry", registry);
        string memory toml = _vm.serializeString("root", "state_transition", stateTransition);
        _vm.writeToml(toml, _outputPath);
    }
}
