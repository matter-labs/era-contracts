// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Governance} from "contracts/governance/Governance.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";

import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";

import {L1NativeTokenVault} from "contracts/bridge/ntv/L1NativeTokenVault.sol";
import {IL1AssetTracker} from "contracts/bridge/asset-tracker/IL1AssetTracker.sol";
import {L1AssetTracker} from "contracts/bridge/asset-tracker/L1AssetTracker.sol";
import {L1ChainAssetHandler} from "contracts/core/chain-asset-handler/L1ChainAssetHandler.sol";
import {IL1ChainAssetHandler} from "contracts/core/chain-asset-handler/IL1ChainAssetHandler.sol";
import {MigrationInterval} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/Ownable2StepUpgradeable.sol";

import {Call} from "contracts/governance/Common.sol";

import {
    L2_CHAIN_ASSET_HANDLER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_VERSION_SPECIFIC_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";
import {UpgradeUtils} from "../default-upgrade/UpgradeUtils.sol";
import {CoreUpgradeParams} from "../default-upgrade/UpgradeParams.sol";
import {TokenMigrationUtils} from "./TokenMigrationUtils.s.sol";

/// FIXME currently we accept ownership as part of stage1, but in fact we should do it as part of stage0.
/// @notice Script used for v31 upgrade flow.
/// @dev Owns all v31-specific core-side ecosystem behavior:
///      - stage 1: AssetTracker.acceptOwnership, NTV.setAssetTracker, ChainAssetHandler.setAddresses
///      - stage 2: legacy-GW historical migration intervals + old-GW blacklist (read from upgrade input TOML)
///      - stage3 (post-governance): bridged-token registration + balance migration
contract CoreUpgrade_v31 is Script, DefaultCoreUpgrade {
    using stdToml for string;

    /// @notice Path to the upgrade input TOML, captured from `initializeWithArgs`
    ///         so that stage-2 helpers can re-read the optional `[legacy_gateway]` section.
    string internal v31UpgradeInputRelPath;

    /// @notice Single-call entry point invoked by the protocol-ops CLI.
    ///         Runs the ecosystem-wide core deploys; CTM deploys are handled by `CTMUpgrade_v31`.
    function noGovernancePrepare(CoreUpgradeParams memory _params) public {
        initializeWithArgs(
            _params.bridgehubProxyAddress,
            _params.isZKsyncOS,
            _params.create2FactorySalt,
            _params.upgradeInputPath,
            _params.outputPath
        );
        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }

    /// @notice Override to capture the upgrade-input relative path so that
    ///         stage-2 governance generation (`prepareVersionSpecificStage2GovernanceCallsL1`)
    ///         can re-read the optional `[legacy_gateway]` section.
    function initializeWithArgs(
        address bridgehubProxyAddress,
        bool isZKsyncOS,
        bytes32 create2FactorySalt,
        string memory upgradeInputPath,
        string memory _outputPath
    ) public virtual override {
        v31UpgradeInputRelPath = upgradeInputPath;
        super.initializeWithArgs(bridgehubProxyAddress, isZKsyncOS, create2FactorySalt, upgradeInputPath, _outputPath);
    }

    function deployNewEcosystemContractsL1() public virtual override {
        deployNewEcosystemContractsL1NoConnections();
        // Configure AssetTracker connections after deployment
        updateContractConnections();
    }

    /// @notice Deploy contracts only (no side effects like setAddresses / transferOwnership).
    /// @dev Used by the test harness for idempotent re-runs where connections are already set up.
    function deployNewEcosystemContractsL1NoConnections() public virtual {
        coreAddresses.bridgehub.implementations.bridgehub = deploySimpleContract("L1Bridgehub", false);
        coreAddresses.bridgehub.implementations.messageRoot = deploySimpleContract("L1MessageRoot", false);
        coreAddresses.bridges.implementations.l1Nullifier = deploySimpleContract("L1Nullifier", false);
        coreAddresses.bridges.implementations.l1AssetRouter = deploySimpleContract("L1AssetRouter", false);
        coreAddresses.bridges.implementations.l1NativeTokenVault = deploySimpleContract("L1NativeTokenVault", false);
        (
            coreAddresses.bridgehub.implementations.assetTracker,
            coreAddresses.bridgehub.proxies.assetTracker
        ) = deployTuppWithContract("L1AssetTracker", false);
        coreAddresses.bridgehub.implementations.ctmDeploymentTracker = deploySimpleContract(
            "CTMDeploymentTracker",
            false
        );
        coreAddresses.bridgehub.implementations.chainAssetHandler = deploySimpleContract("L1ChainAssetHandler", false);
        coreAddresses.bridgehub.implementations.chainRegistrationSender = deploySimpleContract(
            "ChainRegistrationSender",
            false
        );
    }

    /// @notice Configure contract connections after deployment
    /// @dev AssetTracker is new in v31, we initialize it here with deployer as owner, then transfer ownership
    function updateContractConnections() internal {
        console.log("Configuring AssetTracker connections...");

        address assetTrackerProxy = coreAddresses.bridgehub.proxies.assetTracker;
        require(assetTrackerProxy != address(0), "AssetTracker proxy not deployed");

        console.log("AssetTracker proxy:", assetTrackerProxy);
        console.log("Current AssetTracker owner:", Ownable2StepUpgradeable(assetTrackerProxy).owner());
        console.log("Deployer (msg.sender):", msg.sender);

        // Initialize AssetTracker with ChainAssetHandler reference
        // This sets: chainAssetHandler = IChainAssetHandler(BRIDGE_HUB.chainAssetHandler())
        // At this point, deployer is the owner (set in initialize() during proxy deployment)
        console.log("Calling setAddresses() on AssetTracker...");
        vm.broadcast(getBroadcasterAddress());
        IL1AssetTracker(assetTrackerProxy).setAddresses();
        console.log("AssetTracker.setAddresses() completed");

        // Transfer ownership to the proper owner (governance)
        address properOwner = getOwnerAddress();
        console.log("Transferring AssetTracker ownership from deployer to governance:", properOwner);
        vm.broadcast(getBroadcasterAddress());
        Ownable2StepUpgradeable(assetTrackerProxy).transferOwnership(properOwner);
        console.log("AssetTracker ownership transfer initiated (pending acceptance by governance)");
    }

    /*//////////////////////////////////////////////////////////////
                          Internal functions
    //////////////////////////////////////////////////////////////*/

    function getCreationCalldata(
        string memory contractName,
        bool isZKBytecode
    ) internal view override returns (bytes memory) {
        return super.getCreationCalldata(contractName, isZKBytecode);
    }

    /// @notice Override to properly set deployerAddress in upgrade context
    /// @dev In upgrade scripts, msg.sender is the script address, not the broadcast address
    ///      We need to use tx.origin which is the actual transaction sender (private key holder)
    function initializeL1CoreUtilsConfig() internal override {
        super.initializeL1CoreUtilsConfig();

        // In Forge scripts with vm.broadcast(), msg.sender is the script address,
        // but tx.origin is the address of the private key being used for broadcasts.
        // We need to use getBroadcasterAddress() to get the actual deployer address.
        config.deployerAddress = getBroadcasterAddress();
        console.log("Overriding deployerAddress in upgrade context:");
        console.log("  msg.sender (script):", msg.sender);
        console.log("  actual deployer:", getBroadcasterAddress());
        console.log("  config.deployerAddress:", config.deployerAddress);
    }

    function getInitializeCalldata(
        string memory contractName,
        bool isZkBytecode
    ) internal virtual override returns (bytes memory) {
        if (compareStrings(contractName, "L1MessageRoot")) {
            return abi.encodeCall(L1MessageRoot.initializeL1V31Upgrade, ());
        } else if (compareStrings(contractName, "L1AssetTracker")) {
            // Initialize AssetTracker with config.deployerAddress which is now properly set
            // to tx.origin (the address of the private key being used for broadcasts)
            console.log("Initializing L1AssetTracker with deployer as owner:", config.deployerAddress);
            return abi.encodeCall(L1AssetTracker.initialize, (config.deployerAddress));
        }
        return super.getInitializeCalldata(contractName, isZkBytecode);
    }

    /// @notice Override to add version-specific governance calls for stage 1
    /// @dev Stage 1 runs after proxy upgrades, so the new `L1ChainAssetHandler`
    ///      implementation is already in place when these calls execute.
    /// @dev Three calls are emitted:
    ///      1. AssetTracker.acceptOwnership (completes 2-step transfer started during deploy)
    ///      2. NTV.setAssetTracker (wires AssetTracker into NTV)
    ///      3. L1ChainAssetHandler.setAddresses (caches messageRoot/assetRouter from bridgehub)
    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        console.log("Preparing v31-specific stage1 governance calls...");

        // Get NativeTokenVault from AssetRouter
        IL1AssetRouter assetRouter = IL1AssetRouter(coreAddresses.bridges.proxies.l1AssetRouter);
        address ntvProxy = address(assetRouter.nativeTokenVault());
        address assetTrackerProxy = coreAddresses.bridgehub.proxies.assetTracker;
        address chainAssetHandlerProxy = coreAddresses.bridgehub.proxies.chainAssetHandler;

        require(ntvProxy != address(0), "NTV proxy address not found");
        require(assetTrackerProxy != address(0), "AssetTracker proxy address not found");
        require(chainAssetHandlerProxy != address(0), "ChainAssetHandler proxy address not found");

        console.log("Accepting AssetTracker ownership and setting in NativeTokenVault");
        console.log("NTV address:", ntvProxy);
        console.log("AssetTracker address:", assetTrackerProxy);
        console.log("ChainAssetHandler address:", chainAssetHandlerProxy);
        // Note: AssetTracker.setAddresses() was already called during deployment
        // in updateContractConnections(), and ownership was transferred to governance.
        // Now governance needs to accept the ownership transfer.

        calls = new Call[](3);

        // First, accept ownership of AssetTracker (completes the two-step transfer)
        calls[0] = Call({
            target: assetTrackerProxy,
            value: 0,
            data: abi.encodeCall(Ownable2StepUpgradeable.acceptOwnership, ())
        });

        // Set AssetTracker reference in NTV
        calls[1] = Call({
            target: ntvProxy,
            value: 0,
            data: abi.encodeCall(L1NativeTokenVault.setAssetTracker, (assetTrackerProxy))
        });

        // Cache messageRoot/assetRouter inside the new ChainAssetHandler implementation
        // so its facets don't re-query bridgehub on every call.
        calls[2] = Call({
            target: chainAssetHandlerProxy,
            value: 0,
            data: abi.encodeCall(L1ChainAssetHandler.setAddresses, ())
        });

        return calls;
    }

    /// @notice Save v31-specific addresses to output file
    function saveOutputVersionSpecific() public virtual override {
        // Save AssetTracker address for Rust test to read
        vm.writeToml(
            vm.toString(coreAddresses.bridgehub.proxies.assetTracker),
            upgradeConfig.outputPath,
            ".asset_tracker_proxy_addr"
        );
    }

    /// @notice Stage 2 governance calls (post-upgrade-contracts):
    ///         legacy-GW historical migration intervals + old-GW blacklist.
    /// @dev Reads the optional `[legacy_gateway]` section from the upgrade input TOML.
    ///      Returns an empty array if the section is absent (e.g. local fixtures).
    function prepareVersionSpecificStage2GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        return _buildLegacyGatewayDecommissionCalls();
    }

    /// @notice Post-governance migration: register bridged tokens in NTV and
    ///         migrate token balances from NTV into the AssetTracker.
    /// @dev Caller signs as any EOA — no governance privileges required.
    function stage3(address bridgehubProxy) public {
        console.log("Starting v31 stage3 post-governance migration...");
        console.log("Bridgehub proxy:", bridgehubProxy);

        IBridgehubBase bridgehub = IBridgehubBase(bridgehubProxy);
        IL1AssetRouter assetRouter = IL1AssetRouter(address(bridgehub.assetRouter()));
        L1NativeTokenVault ntv = L1NativeTokenVault(payable(address(assetRouter.nativeTokenVault())));
        IL1AssetTracker assetTracker = ntv.l1AssetTracker();

        console.log("AssetRouter:", address(assetRouter));
        console.log("NativeTokenVault:", address(ntv));
        console.log("AssetTracker:", address(assetTracker));

        require(address(assetTracker) != address(0), "AssetTracker not set");

        vm.startBroadcast();
        TokenMigrationUtils.registerBridgedTokensInNTV(address(bridgehub));
        TokenMigrationUtils.migrateAllTokenBalances(address(ntv), address(assetTracker), bridgehub);
        vm.stopBroadcast();

        console.log("v31 stage3 migration complete!");
    }

    /// @notice Build the legacy-GW decommission calls (historical intervals + blacklist).
    /// @dev Reads `[legacy_gateway]` from the upgrade input TOML:
    ///      - `legacy_gateway.chain_id` — the old GW's chain ID (required if section present)
    ///      - `[[legacy_gateway.chain_intervals]]` — one entry per (chain, migration)
    ///      Returns an empty array if the section is missing.
    function _buildLegacyGatewayDecommissionCalls() internal returns (Call[] memory calls) {
        if (bytes(v31UpgradeInputRelPath).length == 0) {
            return new Call[](0);
        }

        string memory root = vm.projectRoot();
        string memory upgradeToml = vm.readFile(string.concat(root, v31UpgradeInputRelPath));

        if (!upgradeToml.keyExists("$.legacy_gateway")) {
            console.log("[legacy_gateway] section absent from upgrade input - skipping decommission calls");
            return new Call[](0);
        }

        uint256 oldGwChainId = upgradeToml.readUint("$.legacy_gateway.chain_id");
        require(oldGwChainId != 0, "legacy_gateway.chain_id must be non-zero");

        address bridgehubProxy = coreAddresses.bridgehub.proxies.bridgehub;
        address chainAssetHandlerProxy = coreAddresses.bridgehub.proxies.chainAssetHandler;
        require(bridgehubProxy != address(0), "bridgehub proxy not discovered");
        require(chainAssetHandlerProxy != address(0), "chainAssetHandler proxy not discovered");

        Call[] memory intervalCalls = _buildHistoricalMigrationIntervalCalls(
            upgradeToml,
            chainAssetHandlerProxy,
            oldGwChainId
        );

        // Blacklist comes last in the merged stage-2 calls.
        Call[] memory blacklistCall = new Call[](1);
        blacklistCall[0] = Call({
            target: bridgehubProxy,
            value: 0,
            data: abi.encodeCall(IL1Bridgehub.setSettlementLayerStatus, (oldGwChainId, false))
        });

        Call[][] memory merge = new Call[][](2);
        merge[0] = intervalCalls;
        merge[1] = blacklistCall;
        calls = UpgradeUtils.mergeCallsArray(merge);

        console.log("Legacy GW chain ID:", oldGwChainId);
        console.log("Historical interval calls:", intervalCalls.length);
    }

    /// @notice Emit one `setHistoricalMigrationInterval` call per `[[legacy_gateway.chain_intervals]]` entry.
    function _buildHistoricalMigrationIntervalCalls(
        string memory upgradeToml,
        address chainAssetHandlerProxy,
        uint256 oldGwChainId
    ) internal returns (Call[] memory calls) {
        if (!upgradeToml.keyExists("$.legacy_gateway.chain_intervals")) {
            return new Call[](0);
        }

        uint256 count = _countTomlArrayLength(upgradeToml, "$.legacy_gateway.chain_intervals");
        calls = new Call[](count);

        for (uint256 i = 0; i < count; ++i) {
            string memory base = string.concat("$.legacy_gateway.chain_intervals[", vm.toString(i), "]");
            uint256 chainId = upgradeToml.readUint(string.concat(base, ".chain_id"));
            MigrationInterval memory interval = MigrationInterval({
                migrateToGWBatchNumber: upgradeToml.readUint(string.concat(base, ".migrate_to_sl_batch")),
                migrateFromGWBatchNumber: upgradeToml.readUint(string.concat(base, ".migrate_from_sl_batch")),
                settlementLayerBatchLowerBound: upgradeToml.readUint(string.concat(base, ".sl_batch_lower_bound")),
                settlementLayerBatchUpperBound: upgradeToml.readUint(string.concat(base, ".sl_batch_upper_bound")),
                settlementLayerChainId: oldGwChainId,
                isActive: false
            });
            calls[i] = Call({
                target: chainAssetHandlerProxy,
                value: 0,
                data: abi.encodeCall(IL1ChainAssetHandler.setHistoricalMigrationInterval, (chainId, 0, interval))
            });
        }
    }

    /// @notice Probe the length of a TOML array by binary search.
    /// @dev Capped at 1024 entries — this is a per-chain legacy-migration list.
    function _countTomlArrayLength(string memory toml, string memory arrayKey) internal returns (uint256) {
        uint256 lo = 0;
        uint256 hi = 1024;
        require(
            !toml.keyExists(string.concat(arrayKey, "[", vm.toString(hi), "]")),
            "legacy_gateway.chain_intervals exceeds 1024 entries"
        );
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            if (toml.keyExists(string.concat(arrayKey, "[", vm.toString(mid), "]"))) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }
}
