// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdToml} from "forge-std/StdToml.sol";

import {CoreUpgrade_v35} from "deploy-scripts/upgrade/v35/CoreUpgrade_v35.s.sol";
import {CTMUpgrade_v35} from "deploy-scripts/upgrade/v35/CTMUpgrade_v35.s.sol";
import {TrimmedUpgradeOutput} from "./_EcosystemUpgradeForTests.sol";

/// @notice Memory-trimmed test variants of the v35 (first registry-driven) Core/CTM prepare
///         scripts, driven by the anvil-interop pipeline upgrade runner through protocol-ops
///         right after the v34 bootstrap hop (`--core-script-path` / `--ctm-script-path`).

/// @dev Same trimming as the v34 variant: the target version comes from the upgrade input, and the
///      output carries only what the runner and the merger read.
contract CTMUpgradeForTests_v35 is CTMUpgrade_v35 {
    using stdToml for string;

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

    function saveOutput(string memory outputPath) internal override {
        TrimmedUpgradeOutput.write(
            vm,
            outputPath,
            getChainUpgradeDiamondCutData(),
            getAddresses().stateTransition.defaultUpgrade,
            TrimmedUpgradeOutput.Registry({
                ctmTransition: upgradeAddresses.ctmTransition,
                ctmUpgradeExecutor: boundCTMUpgradeExecutor(),
                ctmRelease: getAddresses().stateTransition.currentRelease,
                coreRegistry: upgradeAddresses.coreRegistry
            })
        );
    }
}

/// @dev Core upgrade for the harness; the version script needs no trimming on the core side.
contract CoreUpgradeForTests_v35 is CoreUpgrade_v35 {}
