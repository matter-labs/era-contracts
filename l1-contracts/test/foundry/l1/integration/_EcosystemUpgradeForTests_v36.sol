// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdToml} from "forge-std/StdToml.sol";

import {CoreUpgrade_v36} from "deploy-scripts/upgrade/v36/CoreUpgrade_v36.s.sol";
import {CTMUpgrade_v36} from "deploy-scripts/upgrade/v36/CTMUpgrade_v36.s.sol";
import {TrimmedUpgradeOutput} from "./_EcosystemUpgradeForTests.sol";
import {MemberDeploymentsRecord} from "deploy-scripts/utils/MemberDeploymentsRecord.sol";

/// @notice Test variants of the v36 Core/CTM prepare scripts, driven by the anvil-interop pipeline upgrade runner
///         through protocol-ops (`--core-script-path` / `--ctm-script-path`).

/// @dev The target version comes from the upgrade input, and the output carries only what the runner and
///      the merger read.
// solhint-disable-next-line contract-name-capwords
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
                ctmInfrastructureTransition: upgradeAddresses.ctmInfrastructureTransition
            }),
            _reviewed: TrimmedUpgradeOutput.Reviewed({
                create2FactorySalt: _create2FactorySalt,
                chainTypeManagerProxy: getAddresses().stateTransition.proxies.chainTypeManager,
                transparentProxyAdmin: getAddresses().admin.transparentProxyAdmin,
                forceDeploymentsData: generatedData.forceDeploymentsData
            }),
            _memberDeployments: MemberDeploymentsRecord.serialize(memberDeployments)
        });
    }
}

/// @dev Core upgrade for the release edge over the previous release's anvil states, whose `L1ChainAssetHandler` and
///      `L1MessageRoot` proxies run harness variants (`L1ChainAssetHandlerDev`, `DummyL1MessageRoot`): no release
///      build matches them, so the edge replaces them like declared changes, as the Foundry fixture's
///      `CoreUpgradeForLocalTest` does.
// solhint-disable-next-line contract-name-capwords
contract CoreUpgradeForTests_v36 is CoreUpgrade_v36 {
    function changedEcosystemImplementations() internal view override returns (string[] memory names) {
        string[] memory declared = super.changedEcosystemImplementations();
        names = new string[](declared.length + 2);
        for (uint256 i = 0; i < declared.length; ++i) {
            names[i] = declared[i];
        }
        names[declared.length] = "L1ChainAssetHandler";
        names[declared.length + 1] = "L1MessageRoot";
    }
}
