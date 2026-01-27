// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Call} from "contracts/governance/Common.sol";
import {DefaultCoreUpgrade} from "./DefaultCoreUpgrade.s.sol";
import {DefaultCTMUpgrade} from "./DefaultCTMUpgrade.s.sol";
import {UpgradeUtils} from "./UpgradeUtils.sol";
import {BridgehubAddresses} from "../../ecosystem/DeployL1CoreUtils.s.sol";

/// @notice Unified script that runs both ecosystem core upgrade and CTM upgrade
/// @dev This script combines DefaultCoreUpgrade and DefaultCTMUpgrade, running them in sequence
///      and merging their governance calls.
contract DefaultEcosystemUpgrade is Script {
    using stdToml for string;

    DefaultCoreUpgrade internal coreUpgrade;
    DefaultCTMUpgrade internal ctmUpgrade;

    bool internal _coreInitialized;
    bool internal _ctmInitialized;

    string internal ecosystemOutputPath;
    string internal coreOutputPath;
    string internal ctmOutputPath;

    /// @notice Create core upgrade instance - can be overridden for version-specific instances
    function createCoreUpgrade() internal virtual returns (DefaultCoreUpgrade) {
        return new DefaultCoreUpgrade();
    }

    /// @notice Create CTM upgrade instance - can be overridden for version-specific instances
    function createCTMUpgrade() internal virtual returns (DefaultCTMUpgrade) {
        return new DefaultCTMUpgrade();
    }

    /// @notice Get core output path - can be overridden for version-specific paths
    /// @dev Returns relative path (without project root), as it will be concatenated in initialize()
    function getCoreOutputPath(string memory _ecosystemOutputPath) internal virtual returns (string memory) {
        // Default: use environment variable if set, otherwise derive from ecosystem path
        try vm.envString("UPGRADE_CORE_OUTPUT") returns (string memory coreOutputEnv) {
            return coreOutputEnv;
        } catch {
            // Fallback: same as ecosystem output (passed as parameter, already relative)
            return _ecosystemOutputPath;
        }
    }

    /// @notice Get CTM output path - can be overridden for version-specific paths
    /// @dev Returns relative path (without project root), as it will be concatenated in initialize()
    function getCTMOutputPath() internal virtual returns (string memory) {
        // Default: use environment variable if set, otherwise extract from ecosystem output path
        try vm.envString("UPGRADE_CTM_OUTPUT") returns (string memory ctmOutputEnv) {
            return ctmOutputEnv;
        } catch {
            revert("UPGRADE_CTM_OUTPUT environment variable is not set");
        }
    }

    /// @notice Initialize both core and CTM upgrades
    function initialize(
        string memory permanentValuesInputPath,
        string memory upgradeInputPath,
        string memory _ecosystemOutputPath
    ) public virtual {
        string memory root = vm.projectRoot();
        ecosystemOutputPath = string.concat(root, _ecosystemOutputPath);

        // Get output paths (these return relative paths)
        string memory _coreOutputPath = getCoreOutputPath(_ecosystemOutputPath);
        string memory _ctmOutputPath = getCTMOutputPath();

        // Store full paths for later use
        coreOutputPath = string.concat(root, _coreOutputPath);
        ctmOutputPath = string.concat(root, _ctmOutputPath);

        // Initialize core upgrade with its own output path
        coreUpgrade = createCoreUpgrade();
        coreUpgrade.initialize(permanentValuesInputPath, upgradeInputPath, _coreOutputPath);
        _coreInitialized = true;

        // Initialize CTM upgrade with its own output path
        ctmUpgrade = createCTMUpgrade();
        ctmUpgrade.initialize(permanentValuesInputPath, upgradeInputPath, _ctmOutputPath);
        _ctmInitialized = true;

        // Allow subclasses to override protocol version for local testing
        overrideProtocolVersionForLocalTesting(upgradeInputPath);
    }

    /// @notice Override this in test environments to set protocol version from config instead of genesis
    /// @dev By default, does nothing - CTM reads protocol version from genesis config
    function overrideProtocolVersionForLocalTesting(string memory upgradeInputPath) internal virtual {
        // Default: no override, use genesis protocol version
    }

    /// @notice Deploy new ecosystem contracts (delegates to core upgrade)
    function deployNewEcosystemContractsL1() public virtual {
        require(_coreInitialized, "Core upgrade not initialized");
        coreUpgrade.deployNewEcosystemContractsL1();
    }

    /// @notice Get owner address (delegates to core upgrade)
    function getOwnerAddress() public virtual returns (address) {
        require(_coreInitialized, "Core upgrade not initialized");
        return coreUpgrade.getOwnerAddress();
    }

    /// @notice Get discovered bridgehub (delegates to core upgrade)
    function getDiscoveredBridgehub() public virtual returns (BridgehubAddresses memory) {
        require(_coreInitialized, "Core upgrade not initialized");
        return coreUpgrade.getDiscoveredBridgehub();
    }

    /// @notice Get CTM upgrade instance (for test access)
    function getCTMUpgrade() public virtual returns (DefaultCTMUpgrade) {
        require(_ctmInitialized, "CTM upgrade not initialized");
        return ctmUpgrade;
    }

    /// @notice Run full ecosystem upgrade (core + CTM)
    function prepareEcosystemUpgrade() public virtual {
        require(_coreInitialized && _ctmInitialized, "Not initialized");

        console.log("Starting unified ecosystem upgrade...");

        // Step 1: Deploy new ecosystem contracts (core)
        console.log("Step 1: Deploying new ecosystem contracts...");
        coreUpgrade.prepareEcosystemUpgrade();

        // Step 2: Prepare CTM upgrade (includes generating upgrade cut data)
        console.log("Step 2: Preparing CTM upgrade...");
        ctmUpgrade.prepareCTMUpgrade();

        // Step 3: Save combined output including diamond cut data from CTM upgrade
        console.log("Step 3: Saving combined output...");
        saveCombinedOutput();

        console.log("Ecosystem upgrade preparation complete!");
    }

    /// @notice Save combined output including CTM diamond cut data to ecosystem output
    function saveCombinedOutput() internal virtual {
        // Read the CTM output to get the diamond cut data (ctmOutputPath is already full path)
        string memory ctmOutputToml = vm.readFile(ctmOutputPath);
        bytes memory upgradeCutData = ctmOutputToml.readBytes("$.chain_upgrade_diamond_cut");

        // Write the diamond cut data to the ecosystem output (create initial file with just diamond cut)
        // Note: Governance calls will be appended later
        string memory toml = vm.serializeBytes("root", "chain_upgrade_diamond_cut", upgradeCutData);
        vm.writeToml(toml, ecosystemOutputPath);

        console.log("Diamond cut data saved to ecosystem output!");
    }

    /// @notice Combine governance calls from both core and CTM upgrades
    function prepareDefaultGovernanceCalls()
        public
        virtual
        returns (Call[] memory stage0Calls, Call[] memory stage1Calls, Call[] memory stage2Calls)
    {
        console.log("Preparing combined governance calls...");

        // Get governance calls from core upgrade
        (Call[] memory coreStage0, Call[] memory coreStage1, Call[] memory coreStage2) = coreUpgrade
            .prepareDefaultGovernanceCalls();

        // Get governance calls from CTM upgrade
        (Call[] memory ctmStage0, Call[] memory ctmStage1, Call[] memory ctmStage2) = ctmUpgrade
            .prepareDefaultGovernanceCalls();

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

        vm.writeToml(governanceCallsSerialized, ecosystemOutputPath, ".governance_calls");

        console.log("Combined governance calls prepared!");
        console.log("Stage 0 calls:", stage0Calls.length);
        console.log("Stage 1 calls:", stage1Calls.length);
        console.log("Stage 2 calls:", stage2Calls.length);
    }

    /// @notice E2e upgrade generation
    function run() public virtual {
        initialize(
            vm.envString("PERMANENT_VALUES_INPUT"),
            vm.envString("UPGRADE_INPUT"),
            vm.envString("UPGRADE_ECOSYSTEM_OUTPUT")
        );
        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }
}
