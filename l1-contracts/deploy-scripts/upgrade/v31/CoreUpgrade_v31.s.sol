// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";
import {stdToml} from "forge-std/StdToml.sol";

import {Governance} from "contracts/governance/Governance.sol";

import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {InitializeDataNewChain as DiamondInitializeDataNewChain} from "contracts/state-transition/chain-interfaces/IDiamondInit.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1Nullifier} from "contracts/bridge/interfaces/IL1Nullifier.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";

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
import {ICoreUpgradeV31} from "contracts/script-interfaces/IUpgradeV31.sol";
import {UpgradeUtils} from "../default-upgrade/UpgradeUtils.sol";
import {CoreUpgradeParams} from "../default-upgrade/UpgradeParams.sol";
import {TokenMigrationUtils} from "./TokenMigrationUtils.s.sol";
import {BridgedOutPopulationLib} from "../default-upgrade/BridgedOutPopulationLib.sol";

/// FIXME currently we accept ownership as part of stage1, but in fact we should do it as part of stage0.
/// @notice Script used for v31 upgrade flow.
/// @dev Owns all v31-specific core-side ecosystem behavior:
///      - stage 1: ChainRegistrationSender implementation upgrade, ChainAssetHandler.setAddresses
///      - stage 2: legacy-GW historical migration intervals + old-GW blacklist (read from upgrade input TOML)
///      - stage3 (post-governance): bridged-token registration in the NTV + `bridgedOut` population
contract CoreUpgrade_v31 is Script, DefaultCoreUpgrade, ICoreUpgradeV31 {
    using stdToml for string;

    /// @notice Path to the upgrade input TOML, captured from `initializeWithArgs`
    ///         so that stage-2 helpers can re-read the optional `[legacy_gateway]` section.
    string internal v31UpgradeInputRelPath;

    /// @notice Whether this run deployed the `L1InteropHandler` proxy, i.e. the ecosystem was pre-v32.
    ///         Its ownership then has to be handed to governance and its address wired into the bridges.
    bool internal deployedL1InteropHandler;

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
        updateContractConnections();
    }

    /// @notice Deploy contracts only (no side effects like setAddresses / transferOwnership).
    /// @dev Used by the test harness for idempotent re-runs where connections are already set up.
    function deployNewEcosystemContractsL1NoConnections() public virtual {
        coreAddresses.bridgehub.implementations.bridgehub = deploySimpleContract("L1Bridgehub");
        coreAddresses.bridgehub.implementations.messageRoot = deploySimpleContract("L1MessageRoot");
        coreAddresses.bridges.implementations.l1Nullifier = deploySimpleContract("L1Nullifier");
        coreAddresses.bridges.implementations.l1AssetRouter = deploySimpleContract("L1AssetRouter");
        coreAddresses.bridges.implementations.l1NativeTokenVault = deploySimpleContract("L1NativeTokenVault");
        coreAddresses.bridgehub.implementations.ctmDeploymentTracker = deploySimpleContract("CTMDeploymentTracker");
        coreAddresses.bridgehub.implementations.chainAssetHandler = deploySimpleContract("L1ChainAssetHandler");

        // The sender exists since v31, and its proxy is kept: it holds the registration history, and the
        // bridgehub authorizes service transactions by that address. Only the implementation is refreshed
        // (its validation changed in this release), through the proxy upgrade in stage 1.
        require(
            coreAddresses.bridgehub.proxies.chainRegistrationSender != address(0),
            "Bridgehub has no ChainRegistrationSender registered; register it before this upgrade"
        );
        coreAddresses.bridgehub.implementations.chainRegistrationSender = deploySimpleContract(
            "ChainRegistrationSender"
        );

        // The interop handler is new in v32: a pre-v32 ecosystem has no proxy for it, so deploy one and let
        // stage 1 wire it into the bridges. An ecosystem already on v32 only gets a fresh implementation.
        if (coreAddresses.bridges.proxies.l1InteropHandler == address(0)) {
            (
                coreAddresses.bridges.implementations.l1InteropHandler,
                coreAddresses.bridges.proxies.l1InteropHandler
            ) = deployTuppWithContract("L1InteropHandler");
            deployedL1InteropHandler = true;
        } else {
            coreAddresses.bridges.implementations.l1InteropHandler = deploySimpleContract("L1InteropHandler");
        }
    }

    /// @notice Configure contract connections after deployment
    function updateContractConnections() internal {
        address properOwner = getOwnerAddress();

        if (deployedL1InteropHandler) {
            console.log("Transferring L1InteropHandler ownership to governance:", properOwner);
            vm.broadcast(getBroadcasterAddress());
            Ownable2StepUpgradeable(coreAddresses.bridges.proxies.l1InteropHandler).transferOwnership(properOwner);
        }
    }

    /*//////////////////////////////////////////////////////////////
                          Internal functions
    //////////////////////////////////////////////////////////////*/

    function getCreationCalldata(string memory contractName) internal view override returns (bytes memory) {
        return super.getCreationCalldata(contractName);
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

    /// @notice Override to add version-specific governance calls for stage 1
    /// @dev Stage 1 runs after proxy upgrades, so the new `L1ChainAssetHandler`
    ///      implementation is already in place when these calls execute.
    /// @dev Emits the ChainRegistrationSender proxy upgrade, L1ChainAssetHandler.setAddresses,
    ///      and the L1InteropHandler wiring calls (see `_buildL1InteropHandlerWiringCalls`).
    function prepareVersionSpecificStage1GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        console.log("Preparing v32-specific stage1 governance calls...");

        address chainAssetHandlerProxy = coreAddresses.bridgehub.proxies.chainAssetHandler;
        require(chainAssetHandlerProxy != address(0), "ChainAssetHandler proxy address not found");
        console.log("ChainAssetHandler address:", chainAssetHandlerProxy);

        Call[][] memory allCalls = new Call[][](2);

        allCalls[0] = new Call[](2);

        // Point the inherited ChainRegistrationSender proxy at the refreshed implementation.
        allCalls[0][0] = _buildCallProxyUpgrade(
            coreAddresses.bridgehub.proxies.chainRegistrationSender,
            coreAddresses.bridgehub.implementations.chainRegistrationSender
        );

        // Cache messageRoot/assetRouter inside the new ChainAssetHandler implementation
        // so its facets don't re-query bridgehub on every call.
        allCalls[0][1] = Call({
            target: chainAssetHandlerProxy,
            value: 0,
            data: abi.encodeCall(L1ChainAssetHandler.setAddresses, ())
        });

        allCalls[1] = _buildL1InteropHandlerWiringCalls();

        return UpgradeUtils.mergeCallsArray(allCalls);
    }

    /// @notice Stage-1 calls that wire a freshly deployed `L1InteropHandler` into the bridges.
    /// @dev Empty on an ecosystem that already runs v32, so the same script serves an upgrade and a re-run.
    ///      Both setters are one-shot and only exist on the new implementations, hence stage 1 rather than
    ///      the deploy step.
    function _buildL1InteropHandlerWiringCalls() internal virtual returns (Call[] memory calls) {
        // Checked before the early return below: a zero address here means discovery failed to report the
        // handler, which is a broken run whether or not this script deployed it.
        address l1InteropHandlerProxy = coreAddresses.bridges.proxies.l1InteropHandler;
        require(l1InteropHandlerProxy != address(0), "L1InteropHandler proxy not deployed");

        if (!deployedL1InteropHandler) {
            return calls;
        }

        console.log("Wiring the freshly deployed L1InteropHandler:", l1InteropHandlerProxy);
        calls = new Call[](3);
        calls[0] = Call({
            target: l1InteropHandlerProxy,
            value: 0,
            data: abi.encodeCall(Ownable2StepUpgradeable.acceptOwnership, ())
        });
        calls[1] = Call({
            target: coreAddresses.bridges.proxies.l1Nullifier,
            value: 0,
            data: abi.encodeCall(IL1Nullifier.setL1InteropHandler, (l1InteropHandlerProxy))
        });
        calls[2] = Call({
            target: coreAddresses.bridges.proxies.l1AssetRouter,
            value: 0,
            data: abi.encodeCall(IL1AssetRouter.setL1InteropHandler, (l1InteropHandlerProxy))
        });
    }

    /// @notice Stage 2 governance calls (post-upgrade-contracts):
    ///         legacy-GW historical migration intervals + old-GW blacklist.
    /// @dev Reads the optional `[legacy_gateway]` section from the upgrade input TOML.
    ///      Returns an empty array if the section is absent (e.g. local fixtures).
    /// @dev The new-GW bring-up (whitelist + CTM registration + settlement-fee
    ///      configuration + asset-handler wiring) lives in
    ///      `deploy-scripts/gateway/GatewayVotePreparation.s.sol` — protocol-ops
    ///      runs that script as a separate step in `ecosystem upgrade-prepare-all`
    ///      and merges its `governance_calls_to_execute` into the same stage-2
    ///      hex via `write_merged_ecosystem_toml`. Keeping the two sources
    ///      separate lets `GatewayVotePreparation` stay reusable for any future
    ///      GW bring-up (not v31-specific).
    function prepareVersionSpecificStage2GovernanceCallsL1() public virtual override returns (Call[] memory calls) {
        return _buildLegacyGatewayDecommissionCalls();
    }

    /// @notice Post-governance step: register legacy bridged tokens in the NTV bridged-tokens list, then
    ///         populate the vault's `bridgedOut` accounting from the legacy per-chain balances.
    /// @dev Caller signs as any EOA — no governance privileges required.
    /// @dev The registration has to come first: the population only sees assets that are present in the
    ///      vault's `bridgedTokens` enumeration.
    function stage3(address bridgehubProxy) public {
        console.log("Starting v32 stage3 post-governance registration...");
        console.log("Bridgehub proxy:", bridgehubProxy);

        vm.startBroadcast();
        TokenMigrationUtils.registerBridgedTokensInNTV(bridgehubProxy);
        BridgedOutPopulationLib.populateBridgedOutForAllAssets(bridgehubProxy);
        vm.stopBroadcast();

        console.log("v32 stage3 registration complete!");
    }

    /// @notice Build the legacy-GW decommission calls (historical intervals + blacklist).
    /// @dev Reads `[legacy_gateway]` from `upgrade-envs/permanent-values/<env>.toml`
    ///      (the historical/env-stable file), not the v31-specific upgrade input.
    ///      The basename is extracted from `v31UpgradeInputRelPath` (e.g.
    ///      `/upgrade-envs/v0.31.0-interopB/stage.toml` → reads
    ///      `/upgrade-envs/permanent-values/stage.toml`).
    ///      - `legacy_gateway.chain_id` — the old GW's chain ID (required if section present)
    ///      - `[[legacy_gateway.chain_intervals]]` — one entry per (chain, migration)
    ///      Returns an empty array if the section is missing or `v31UpgradeInputRelPath`
    ///      is unset (local fixtures).
    function _buildLegacyGatewayDecommissionCalls() internal returns (Call[] memory calls) {
        if (bytes(v31UpgradeInputRelPath).length == 0) {
            return new Call[](0);
        }

        string memory root = vm.projectRoot();
        string memory permanentValuesRelPath = _permanentValuesPathFromV31Input();
        string memory upgradeToml = vm.readFile(string.concat(root, permanentValuesRelPath));

        if (!upgradeToml.keyExists("$.legacy_gateway")) {
            console.log("[legacy_gateway] absent from permanent-values - skipping decommission calls");
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

    /// @notice Derive the permanent-values TOML path from the v31 upgrade input
    ///         path. The two files share a basename per env:
    ///           v31 input:        `/upgrade-envs/v0.31.0-interopB/<env>.toml`
    ///           permanent-values: `/upgrade-envs/permanent-values/<env>.toml`
    ///         We extract the basename of `v31UpgradeInputRelPath` and rebuild
    ///         the path under `permanent-values/`.
    ///         Honors `PERMANENT_VALUES_INPUT_OVERRIDE` when set, so test harnesses
    ///         that render the file into a scratch dir can point us at it directly.
    function _permanentValuesPathFromV31Input() internal view returns (string memory) {
        string memory override_ = vm.envOr("PERMANENT_VALUES_INPUT_OVERRIDE", string(""));
        if (bytes(override_).length > 0) {
            return override_;
        }
        bytes memory p = bytes(v31UpgradeInputRelPath);
        require(p.length > 0, "v31UpgradeInputRelPath empty");
        uint256 lastSlash = 0;
        bool found = false;
        for (uint256 i = p.length; i > 0; --i) {
            if (p[i - 1] == "/") {
                lastSlash = i;
                found = true;
                break;
            }
        }
        require(found, "v31UpgradeInputRelPath has no `/` separator");
        bytes memory basename = new bytes(p.length - lastSlash);
        for (uint256 i = 0; i < basename.length; ++i) {
            basename[i] = p[lastSlash + i];
        }
        return string.concat("/upgrade-envs/permanent-values/", string(basename));
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
