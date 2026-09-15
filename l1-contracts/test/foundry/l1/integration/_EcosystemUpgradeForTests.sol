// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {CoreUpgrade_v34} from "deploy-scripts/upgrade/v34/CoreUpgrade_v34.s.sol";
import {CTMUpgrade_v34} from "deploy-scripts/upgrade/v34/CTMUpgrade_v34.s.sol";

/// @notice Memory-trimmed test variants of the CURRENT version's Core/CTM upgrade scripts,
///         driven by the anvil-interop pipeline upgrade runner through protocol-ops
///         (`--core-script-path` / `--ctm-script-path` overrides). Repoint the parents when the
///         next version's scripts land — the runner itself is version-independent.

/// @dev CTM upgrade for the harness: publishes the factory dependencies for real (the
///      bootstrap object refuses a plan whose bytecodes are not on the CTM's supplier — the
///      anvil L2 stand-ins get theirs via `anvil_setCode`, but the L1 record must exist), reads
///      the upgrade target version from the upgrade input (the production flow reads it from
///      the genesis config, which pins the release this branch is built against; a harness
///      scenario upgrading an older fixture onto this release has to say where it is going),
///      and writes only the minimal output the runner needs so accumulated `vm.serialize*`
///      JSON does not blow forge's EVM memory.
contract CTMUpgradeForTests is CTMUpgrade_v34 {
    using stdToml for string;

    // solhint-disable-next-line func-named-parameters
    function initializeWithArgs(
        address _ctmProxy,
        address _rollupDAManager,
        bytes32 _create2FactorySalt,
        string memory _newConfigPath,
        string memory _outputPath,
        address _governance,
        bytes32 _zkTokenAssetId,
        bool _testnetVerifier
    ) public virtual override {
        // solhint-disable-next-line func-named-parameters
        super.initializeWithArgs(
            _ctmProxy,
            _rollupDAManager,
            _create2FactorySalt,
            _newConfigPath,
            _outputPath,
            _governance,
            _zkTokenAssetId,
            _testnetVerifier
        );

        string memory upgradeToml = vm.readFile(string.concat(vm.projectRoot(), _newConfigPath));
        if (upgradeToml.keyExists("$.contracts.new_protocol_version")) {
            setNewProtocolVersion(upgradeToml.readUint("$.contracts.new_protocol_version"));
        }
    }

    /// @dev Replaces the heavy state_transition section with the fields the anvil-interop runner
    ///      and the protocol-ops merger actually read: the committed diamond cut, the engine
    ///      address and the `[registry]` objects (the merger recognizes executor stage calls by the
    ///      executor address written there).
    function saveOutput(string memory outputPath) internal override {
        TrimmedUpgradeOutput.write(
            vm,
            outputPath,
            getChainUpgradeDiamondCutData(),
            committedUpgradeEngine(),
            getAddresses().admin.eip7702Checker,
            TrimmedUpgradeOutput.Registry({
                // A bootstrap edge has no transition, so this prepare deploys no operation;
                // the executor it hands the domain to is still named.
                ctmTransition: address(0),
                ctmUpgradeExecutor: boundCTMUpgradeExecutor(),
                ctmRelease: getAddresses().stateTransition.currentRelease,
                upgradeTimer: upgradeAddresses.upgradeTimer,
                bootstrapMigration: bootstrapMigrationAddress(),
                // A bootstrap edge composes no operation: it has no transition, and its own
                // sequence object carries every call.
                operation: address(0),
                coordinator: address(0)
            })
        );
    }
}

/// @dev The trimmed per-CTM output both harness variants write.
library TrimmedUpgradeOutput {
    struct Registry {
        address ctmTransition;
        address ctmUpgradeExecutor;
        address ctmRelease;
        address upgradeTimer;
        address bootstrapMigration;
        address operation;
        address coordinator;
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
        Registry memory _registry
    ) internal {
        _vm.serializeAddress("state_transition", "eip7702_checker_addr", _eip7702Checker);
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
        _vm.serializeAddress("registry", "upgrade_timer_addr", _registry.upgradeTimer);
        _vm.serializeAddress("registry", "bootstrap_migration_addr", _registry.bootstrapMigration);
        _vm.serializeAddress("registry", "ctm_upgrade_executor_addr", _registry.ctmUpgradeExecutor);
        // The merge derives this upgrade's three lifecycle calls from exactly these two addresses,
        // so a trimmed output that omitted them would produce a package with no stage calls at all.
        _vm.serializeAddress("registry", "coordinator_addr", _registry.coordinator);
        string memory registry = _vm.serializeAddress("registry", "operation_addr", _registry.operation);
        _vm.serializeBytes("root", "chain_upgrade_diamond_cut", _upgradeCutData);
        _vm.serializeString("root", "registry", registry);
        string memory toml = _vm.serializeString("root", "state_transition", stateTransition);
        _vm.writeToml(toml, _outputPath);
    }
}

/// @dev Core upgrade for the harness; the version script needs no trimming on the core side.
contract CoreUpgradeForTests is CoreUpgrade_v34 {}
