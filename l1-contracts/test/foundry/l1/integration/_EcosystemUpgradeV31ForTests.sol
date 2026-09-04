// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {CoreUpgrade_v31} from "deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol";
import {CTMUpgrade_v31} from "deploy-scripts/upgrade/v31/CTMUpgrade_v31.s.sol";

/// @notice Memory-trimmed test variants of the v31 Core/CTM upgrade scripts and a
///         small Stage-3 wrapper. Used by the anvil-interop fork-upgrade test and the
///         foundry integration tests. There is no `EcosystemUpgrade_v31` orchestrator
///         anymore — callers run Core and CTM scripts directly (or via `protocol-ops
///         upgrade-prepare-all` with `--core-script-path` / `--ctm-script-path`).

/// @dev CTM upgrade for tests: skips factory-deps validation (the harness puts the L2
///      bytecodes in place itself) and writes only the minimal fields the test harness needs
///      so accumulated `vm.serialize*` JSON does not blow forge's 128 MB EVM memory.
contract CTMUpgradeV31ForTests is CTMUpgrade_v31 {
    using stdToml for string;

    function prepareCTMUpgrade() public override {
        setSkipFactoryDepsCheck_TestOnly(true);
        super.prepareCTMUpgrade();
    }

    /// @dev Reads the optional `contracts.new_protocol_version` from the upgrade input and uses it as the
    ///      upgrade target. The production flow reads the target from the genesis config, which pins the
    ///      release the foundry suite is built against (v31); a harness scenario upgrading a v31 ecosystem
    ///      onto this release has to say which version it is moving to, the same way the local foundry
    ///      fixture does with `ctmUpgrade.setNewProtocolVersion`.
    // solhint-disable-next-line func-named-parameters
    function initializeWithArgs(
        address _ctmProxy,
        address _bytecodesSupplier,
        address _rollupDAManager,
        bytes32 _create2FactorySalt,
        string memory _newConfigPath,
        string memory _outputPath,
        address _governance,
        bytes32 _zkTokenAssetId
    ) public virtual override {
        // solhint-disable-next-line func-named-parameters
        super.initializeWithArgs(
            _ctmProxy,
            _bytecodesSupplier,
            _rollupDAManager,
            _create2FactorySalt,
            _newConfigPath,
            _outputPath,
            _governance,
            _zkTokenAssetId
        );

        string memory upgradeToml = vm.readFile(string.concat(vm.projectRoot(), _newConfigPath));
        if (upgradeToml.keyExists("$.contracts.new_protocol_version")) {
            setNewProtocolVersion(upgradeToml.readUint("$.contracts.new_protocol_version"));
        }
    }

    /// @dev Skip loading the L2 bytecodes — they are already on L2 via `anvil_setCode`.
    function publishBytecodes() public override {
        // no-op
    }

    /// @dev Replaces the heavy state_transition section with the fields the
    ///      anvil-interop test reads.
    function saveOutput(string memory outputPath) internal override {
        bytes memory upgradeCutData = getChainUpgradeDiamondCutData();
        address defaultUpgradeAddr = getAddresses().stateTransition.defaultUpgrade;

        vm.serializeAddress("state_transition", "upgrade_precondition_checker_addr", upgradePreconditionChecker);
        string memory stateTransition = vm.serializeAddress(
            "state_transition",
            "default_upgrade_addr",
            defaultUpgradeAddr
        );
        vm.serializeBytes("root", "chain_upgrade_diamond_cut", upgradeCutData);
        string memory toml = vm.serializeString("root", "state_transition", stateTransition);
        vm.writeToml(toml, outputPath);
    }
}

/// @dev Core upgrade for tests with a Stage-3 wrapper that reads bridgehub from env.
///      Anvil-interop drives `stage3()` via direct `forge script`, separate from the
///      protocol-ops driven prepare phase.
contract CoreUpgradeV31ForTests is CoreUpgrade_v31 {
    using stdToml for string;

    /// @notice Stage 3 wrapper: reads bridgehub from `PERMANENT_VALUES_INPUT_OVERRIDE`
    ///         and dispatches to `CoreUpgrade_v31.stage3(bridgehubProxy)`.
    function stage3() public {
        string memory permanentValuesPath = vm.envString("PERMANENT_VALUES_INPUT_OVERRIDE");
        string memory pvToml = vm.readFile(string.concat(vm.projectRoot(), permanentValuesPath));
        address bridgehubProxy = pvToml.readAddress("$.core_contracts.bridgehub_proxy_addr");
        stage3(bridgehubProxy);
    }
}

/// @dev Idempotent variant of CoreUpgradeV31ForTests: skips `updateContractConnections()`
///      so a second run inside the same forge process does not redo `setAddresses` /
///      `transferOwnership`. Required by tests that re-run core deploys to recompute
///      create2 addresses for downstream pieces (e.g. MailboxFacet's chainAssetHandler).
contract CoreUpgradeV31Idempotent is CoreUpgradeV31ForTests {
    function deployNewEcosystemContractsL1() public virtual override {
        super.deployNewEcosystemContractsL1NoConnections();
    }
}
