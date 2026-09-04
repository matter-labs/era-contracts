// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdToml} from "forge-std/StdToml.sol";

import {CoreUpgrade_v34} from "deploy-scripts/upgrade/v34/CoreUpgrade_v34.s.sol";
import {CTMUpgrade_v34} from "deploy-scripts/upgrade/v34/CTMUpgrade_v34.s.sol";

/// @notice Memory-trimmed test variants of the CURRENT version's Core/CTM upgrade scripts,
///         driven by the anvil-interop pipeline upgrade runner through protocol-ops
///         (`--core-script-path` / `--ctm-script-path` overrides). Repoint the parents when the
///         next version's scripts land — the runner itself is version-independent.

/// @dev CTM upgrade for the harness: skips factory-deps validation (zkout bytecodes are not
///      published on the anvil fixtures — they are already on L2 via `anvil_setCode`), reads
///      the upgrade target version from the upgrade input (the production flow reads it from
///      the genesis config, which pins the release this branch is built against; a harness
///      scenario upgrading an older fixture onto this release has to say where it is going),
///      and writes only the minimal output the runner needs so accumulated `vm.serialize*`
///      JSON does not blow forge's EVM memory.
contract CTMUpgradeForTests is CTMUpgrade_v34 {
    using stdToml for string;

    function prepareCTMUpgrade() public override {
        setSkipFactoryDepsCheck_TestOnly(true);
        super.prepareCTMUpgrade();
    }

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

    /// @dev Skip loading zkout bytecodes — they are already on L2 via `anvil_setCode`.
    function publishBytecodes() public override {
        // no-op
    }

    /// @dev Replaces the heavy state_transition section with the two fields the anvil-interop
    ///      runner actually reads (the committed diamond cut + the engine address).
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

/// @dev Core upgrade for the harness; the version script needs no trimming on the core side.
contract CoreUpgradeForTests is CoreUpgrade_v34 {}
