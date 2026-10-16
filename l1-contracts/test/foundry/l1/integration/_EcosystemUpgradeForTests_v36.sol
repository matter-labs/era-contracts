// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdToml} from "forge-std/StdToml.sol";

import {CoreUpgrade_v36} from "deploy-scripts/upgrade/v36/CoreUpgrade_v36.s.sol";
import {CTMUpgrade_v36} from "deploy-scripts/upgrade/v36/CTMUpgrade_v36.s.sol";
import {TrimmedUpgradeOutput} from "./_EcosystemUpgradeForTests.sol";

/// @notice Memory-trimmed test variants of the v36 (first registry-driven) Core/CTM prepare
///         scripts, driven by the anvil-interop pipeline upgrade runner through protocol-ops
///         right after the v35 bootstrap hop (`--core-script-path` / `--ctm-script-path`).

/// @dev The target version comes from the upgrade input, and the output carries only what the runner and
///      the merger read.
contract CTMUpgradeForTests_v36 is CTMUpgrade_v36 {
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

    function saveOutput(string memory outputPath) internal override {
        TrimmedUpgradeOutput.write({
            _vm: vm,
            _outputPath: outputPath,
            _upgradeCutData: getChainUpgradeDiamondCutData(),
            _defaultUpgrade: committedUpgradeEngine(),
            _eip7702Checker: getAddresses().admin.eip7702Checker,
            _registry: TrimmedUpgradeOutput.Registry({
                ctmTransition: upgradeAddresses.ctmTransition,
                ctmUpgradeExecutor: boundCTMUpgradeExecutor(),
                ctmRelease: getAddresses().stateTransition.currentRelease,
                // Not a bootstrap: no migration to name.
                bootstrapMigration: address(0),
                operation: upgradeAddresses.ecosystemUpgradeOperation,
                coordinator: upgradeCoordinator()
            }),
            _reviewed: TrimmedUpgradeOutput.Reviewed({
                create2FactorySalt: _create2FactorySalt,
                chainTypeManagerProxy: getAddresses().stateTransition.proxies.chainTypeManager,
                transparentProxyAdmin: getAddresses().admin.transparentProxyAdmin,
                forceDeploymentsData: generatedData.forceDeploymentsData
            })
        });
    }
}

/// @dev Core upgrade for the harness. The anvil ecosystem this hop runs on was bootstrapped from the
///      current sources, so its `L1MessageRoot` already runs this build and the base pipeline would
///      reuse it; the harness deploys the declared change anyway so the hop carries the ecosystem leg
///      it exists to exercise.
contract CoreUpgradeForTests_v36 is CoreUpgrade_v36 {
    function _canReuseEcosystemImplementation(string memory _name, address _live) internal override returns (bool) {
        if (keccak256(bytes(_name)) == keccak256(bytes("L1MessageRoot"))) {
            return false;
        }
        return super._canReuseEcosystemImplementation(_name, _live);
    }
}
