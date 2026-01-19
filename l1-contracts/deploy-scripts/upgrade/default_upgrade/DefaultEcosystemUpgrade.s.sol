// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Call} from "contracts/governance/Common.sol";
import {DefaultCoreUpgrade} from "./DefaultCoreUpgrade.s.sol";
import {DefaultCTMUpgrade} from "./DefaultCTMUpgrade.s.sol";
import {UpgradeUtils} from "./UpgradeUtils.sol";

/// @notice Unified script that runs both ecosystem core upgrade and CTM upgrade
/// @dev This script combines DefaultCoreUpgrade and DefaultCTMUpgrade, running them in sequence
///      and merging their governance calls.
contract DefaultEcosystemUpgrade is DefaultCoreUpgrade {
    using stdToml for string;

    DefaultCTMUpgrade internal eraVmCtmUpgrade;

    bool internal _coreInitialized;
    bool internal _ctmInitialized;

    string internal _ecosystemOutputPath;
    string internal _ctmOutputPath;

    /// @notice Create CTM upgrade instance - can be overridden for version-specific instances
    function createCTMUpgrade() internal virtual returns (DefaultCTMUpgrade) {
        return new DefaultCTMUpgrade();
    }

    /// @notice Initialize both core and CTM upgrades
    function initialize(
        string memory permanentValuesInputPath,
        string memory upgradeInputPath,
        string memory ecosystemOutputPath
    ) public virtual override {
        string memory root = vm.projectRoot();
        _ecosystemOutputPath = string.concat(root, ecosystemOutputPath);

        // CTM output will be in script-out based on version
        string memory upgradeToml = vm.readFile(string.concat(root, upgradeInputPath));
        uint256 newProtocolVersion = upgradeToml.readUint("$.contracts.new_protocol_version");
        _ctmOutputPath = string.concat(root, "/script-out/v", vm.toString(newProtocolVersion), "-upgrade-core.toml");

        // Initialize core upgrade
        DefaultCoreUpgrade.initialize(permanentValuesInputPath, upgradeInputPath, ecosystemOutputPath);
        _coreInitialized = true;

        // Initialize CTM upgrade with its own output path
        eraVmCtmUpgrade = createCTMUpgrade();
        eraVmCtmUpgrade.initialize(permanentValuesInputPath, upgradeInputPath, _ctmOutputPath);
        _ctmInitialized = true;
    }

    /// @notice Run full ecosystem upgrade (core + CTM)
    function prepareEcosystemUpgrade() public override {
        require(_coreInitialized && _ctmInitialized, "Not initialized");

        console.log("Starting unified ecosystem upgrade...");

        // Step 1: Deploy new ecosystem contracts (core)
        console.log("Step 1: Deploying new ecosystem contracts...");
        DefaultCoreUpgrade.prepareEcosystemUpgrade();

        // Step 2: Prepare CTM upgrade (includes generating upgrade cut data)
        console.log("Step 2: Preparing CTM upgrade...");
        eraVmCtmUpgrade.prepareCTMUpgrade();

        console.log("Ecosystem upgrade preparation complete!");
    }

    /// @notice Combine governance calls from both core and CTM upgrades
    function prepareDefaultGovernanceCalls()
        public
        override
        returns (Call[] memory stage0Calls, Call[] memory stage1Calls, Call[] memory stage2Calls)
    {
        console.log("Preparing combined governance calls...");

        // Get governance calls from core upgrade
        (
            Call[] memory coreStage0,
            Call[] memory coreStage1,
            Call[] memory coreStage2
        ) = DefaultCoreUpgrade.prepareDefaultGovernanceCalls();

        // Get governance calls from CTM upgrade
        (
            Call[] memory ctmStage0,
            Call[] memory ctmStage1,
            Call[] memory ctmStage2
        ) = eraVmCtmUpgrade.prepareDefaultGovernanceCalls();

        // Merge stage 0 calls
        Call[][] memory stage0Array = new Call[][](2);
        stage0Array[0] = coreStage0;
        stage0Array[1] = ctmStage0;
        stage0Calls = UpgradeUtils.mergeCallsArray(stage0Array);

        // Merge stage 1 calls
        Call[][] memory stage1Array = new Call[][](2);
        stage1Array[0] = coreStage1;
        stage1Array[1] = ctmStage1;
        stage1Calls = UpgradeUtils.mergeCallsArray(stage1Array);

        // Merge stage 2 calls
        Call[][] memory stage2Array = new Call[][](2);
        stage2Array[0] = coreStage2;
        stage2Array[1] = ctmStage2;
        stage2Calls = UpgradeUtils.mergeCallsArray(stage2Array);

        // Save combined governance calls to ecosystem output
        vm.serializeBytes("governance_calls", "stage0_calls", abi.encode(stage0Calls));
        vm.serializeBytes("governance_calls", "stage1_calls", abi.encode(stage1Calls));
        string memory governanceCallsSerialized = vm.serializeBytes(
            "governance_calls",
            "stage2_calls",
            abi.encode(stage2Calls)
        );

        vm.writeToml(governanceCallsSerialized, _ecosystemOutputPath, ".governance_calls");

        console.log("Combined governance calls prepared!");
        console.log("Stage 0 calls:", stage0Calls.length);
        console.log("Stage 1 calls:", stage1Calls.length);
        console.log("Stage 2 calls:", stage2Calls.length);
    }

    /// @notice E2e upgrade generation
    function run() public virtual override {
        initialize(
            vm.envString("PERMANENT_VALUES_INPUT"),
            vm.envString("UPGRADE_INPUT"),
            vm.envString("UPGRADE_ECOSYSTEM_OUTPUT")
        );
        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }
}
