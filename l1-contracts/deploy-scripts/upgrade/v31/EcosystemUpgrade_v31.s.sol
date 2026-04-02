// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {IL1AssetTracker} from "contracts/bridge/asset-tracker/IL1AssetTracker.sol";

import {DefaultEcosystemUpgrade} from "../default-upgrade/DefaultEcosystemUpgrade.s.sol";
import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";
import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {CoreUpgrade_v31} from "./CoreUpgrade_v31.s.sol";
import {CTMUpgrade_v31} from "./CTMUpgrade_v31.s.sol";
import {TokenMigrationUtils} from "./TokenMigrationUtils.s.sol";

/// @notice Script used for v31 ecosystem upgrade flow (core + CTM)
/// TODO: IMPORTANT this script should also contain the following steps:
/// - Initialize the previous Gateway migrations via `L1ChainAssetHandler.setHistoricalMigrationInterval`.
/// - Remove the whitelisted settlement layer status from the Era based ZK Gateway `L1Bridgehub.registerSettlementLayer`.
/// - Need to set the initial interop settlement fee on ZK Gateway.
/// - Call "L1ChainAssetHandler.setAddresses()"
contract EcosystemUpgrade_v31 is DefaultEcosystemUpgrade {
    using stdToml for string;

    string internal constant DEFAULT_PERMANENT_VALUES_INPUT = "/upgrade-envs/permanent-values/local.toml";
    string internal constant DEFAULT_UPGRADE_INPUT = "/upgrade-envs/v0.31.0-interopB/local.toml";
    string internal constant DEFAULT_ECOSYSTEM_OUTPUT = "/script-out/v31-upgrade-ecosystem.toml";

    function getPermanentValuesInputPath() internal view returns (string memory) {
        return vm.envOr("PERMANENT_VALUES_INPUT_OVERRIDE", DEFAULT_PERMANENT_VALUES_INPUT);
    }

    function getUpgradeInputPath() internal view returns (string memory) {
        return vm.envOr("UPGRADE_INPUT_OVERRIDE", DEFAULT_UPGRADE_INPUT);
    }

    function getEcosystemOutputPath() internal view returns (string memory) {
        return vm.envOr("UPGRADE_ECOSYSTEM_OUTPUT_OVERRIDE", DEFAULT_ECOSYSTEM_OUTPUT);
    }

    /// @notice Create v31-specific core upgrade instance
    function createCoreUpgrade() internal virtual override returns (DefaultCoreUpgrade) {
        return new CoreUpgrade_v31();
    }

    /// @notice Create v31-specific CTM upgrade instance
    function createCTMUpgrade() internal virtual override returns (DefaultCTMUpgrade) {
        return new CTMUpgrade_v31();
    }

    /// @notice Override to set core output path
    function getCoreOutputPath(string memory _ecosystemOutputPath) internal virtual override returns (string memory) {
        // Use hardcoded path for v31 core output
        return "/script-out/v31-upgrade-core.toml";
    }

    /// @notice Override to set CTM output path
    function getCTMOutputPath() internal virtual override returns (string memory) {
        // Use hardcoded path for v31 CTM output
        return "/script-out/v31-upgrade-ctm.toml";
    }

    /// @notice Initialize with v31-specific permanent values preparation
    function initialize(
        string memory permanentValuesInputPath,
        string memory upgradeInputPath,
        string memory _ecosystemOutputPath
    ) public override {
        string memory root = vm.projectRoot();
        ecosystemOutputPath = string.concat(root, _ecosystemOutputPath);

        // Get output paths (these return relative paths)
        string memory _coreOutputPath = getCoreOutputPath(_ecosystemOutputPath);
        string memory _ctmOutputPath = getCTMOutputPath();

        // Store full paths for later use
        coreOutputPath = string.concat(root, _coreOutputPath);
        ctmOutputPath = string.concat(root, _ctmOutputPath);

        // Create v31 core upgrade
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

    /// @notice E2e upgrade generation
    function run() public override {
        initialize(getPermanentValuesInputPath(), getUpgradeInputPath(), getEcosystemOutputPath());

        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }

    /// @notice Stage 3: Post-governance migration tasks
    /// @dev This should be called after stage 0, 1, and 2 governance calls are executed
    /// @dev Can be called with any private key (doesn't need to be governance)
    function stage3() public {
        console.log("Starting v31 stage3 post-governance migration...");

        // Read the permanent values to get contract addresses
        string memory root = vm.projectRoot();
        string memory permanentValuesPath = string.concat(root, getPermanentValuesInputPath());
        string memory permanentValues = vm.readFile(permanentValuesPath);

        address bridgehubProxy = permanentValues.readAddress("$.core_contracts.bridgehub_proxy_addr");
        console.log("Bridgehub proxy:", bridgehubProxy);

        // Get contract addresses
        IBridgehubBase bridgehub = IBridgehubBase(bridgehubProxy);
        IL1AssetRouter assetRouter = IL1AssetRouter(address(bridgehub.assetRouter()));
        L1NativeTokenVault ntv = L1NativeTokenVault(payable(address(assetRouter.nativeTokenVault())));
        IL1AssetTracker assetTracker = ntv.l1AssetTracker();

        console.log("AssetRouter:", address(assetRouter));
        console.log("NativeTokenVault:", address(ntv));
        console.log("AssetTracker:", address(assetTracker));

        require(address(assetTracker) != address(0), "AssetTracker not set");

        // Register bridged tokens in NTV and migrate balances to AssetTracker
        TokenMigrationUtils.registerBridgedTokensInNTV(address(bridgehub));
        TokenMigrationUtils.migrateAllTokenBalances(address(ntv), address(assetTracker), bridgehub);

        console.log("v31 stage3 migration complete!");
    }

    function getBroadcasterAddress() internal view virtual returns (address) {
        return tx.origin;
    }
}
