// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {CoreUpgrade_v33} from "deploy-scripts/upgrade/v33/CoreUpgrade_v33.s.sol";
import {CTMUpgrade_v33} from "deploy-scripts/upgrade/v33/CTMUpgrade_v33.s.sol";

/// @notice Memory-trimmed test variants of the v33 Core/CTM upgrade scripts and a
///         small Stage-3 wrapper. Used by the anvil-interop fork-upgrade test and the
///         foundry integration tests. There is no `EcosystemUpgrade_v31` orchestrator
///         anymore — callers run Core and CTM scripts directly (or via `protocol-ops
///         upgrade-prepare-all` with `--core-script-path` / `--ctm-script-path`).

/// @dev CTM upgrade for tests: skips factory-deps validation (zkout bytecodes are
///      not available) and writes only the minimal output the test harness needs
///      (`chain_upgrade_diamond_cut` + `state_transition.default_upgrade_addr`)
///      so accumulated `vm.serialize*` JSON does not blow forge's 128 MB EVM memory.
contract CTMUpgradeV33ForTests is CTMUpgrade_v33 {
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
        bool _isZKsyncOS,
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
            _bytecodesSupplier,
            _isZKsyncOS,
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

/// @dev Core upgrade for tests, with the no-arg Stage-3 wrapper the harnesses drive via a direct
///      `forge script` call (separate from the protocol-ops driven prepare phase).
contract CoreUpgradeV33ForTests is CoreUpgrade_v33 {
    using stdToml for string;

    /// @notice Stage 3 wrapper: reads bridgehub from `PERMANENT_VALUES_INPUT_OVERRIDE` and
    ///         dispatches to `stage3(bridgehubProxy)`.
    function stage3() public {
        string memory permanentValuesPath = vm.envString("PERMANENT_VALUES_INPUT_OVERRIDE");
        string memory pvToml = vm.readFile(string.concat(vm.projectRoot(), permanentValuesPath));
        address bridgehubProxy = pvToml.readAddress("$.core_contracts.bridgehub_proxy_addr");
        stage3(bridgehubProxy);
    }
}
