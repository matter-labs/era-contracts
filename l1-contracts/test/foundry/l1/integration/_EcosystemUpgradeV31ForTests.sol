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

/// @dev CTM upgrade for tests: skips factory-deps validation (zkout bytecodes are
///      not available) and writes only the minimal output the test harness needs
///      (`chain_upgrade_diamond_cut` + `state_transition.default_upgrade_addr`)
///      so accumulated `vm.serialize*` JSON does not blow forge's 128 MB EVM memory.
contract CTMUpgradeV31ForTests is CTMUpgrade_v31 {
    function prepareCTMUpgrade() public override {
        setSkipFactoryDepsCheck_TestOnly(true);
        super.prepareCTMUpgrade();
    }

    /// @dev Skip loading zkout bytecodes — they are already on L2 via `anvil_setCode`.
    function publishBytecodes() public override {
        // no-op
    }

    /// @dev Replaces the heavy state_transition section with the two fields the
    ///      anvil-interop test actually reads (diamond cut data + default upgrade addr).
    function saveOutput(string memory outputPath) internal override {
        bytes memory upgradeCutData = getChainUpgradeDiamondCutData();
        address defaultUpgradeAddr = getAddresses().stateTransition.defaultUpgrade;

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
