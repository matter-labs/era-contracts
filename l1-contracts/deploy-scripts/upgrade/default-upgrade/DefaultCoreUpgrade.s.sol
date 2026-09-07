// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {Call} from "contracts/governance/Common.sol";

import {DeployL1CoreUtils} from "../../ecosystem/DeployL1CoreUtils.s.sol";

import {Governance} from "contracts/governance/Governance.sol";
import {CoreRegistry} from "contracts/upgrades/registry/objects/CoreRegistry.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {CoreRegistryManifest, PinnedContract, ProxyUpgradeRow} from "contracts/upgrades/registry/RegistryTypes.sol";
import {
    L1EcosystemContract,
    L1_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {BridgehubAddresses, CoreDeployedAddresses} from "../../utils/Types.sol";

import {AddressIntrospector} from "../../utils/AddressIntrospector.sol";
import {CoreUpgradeParams} from "./UpgradeParams.sol";
import {ExternalActionsLib} from "./ExternalActionsLib.sol";
import {Utils} from "../../utils/Utils.sol";

import {ChainCreationParamsLib} from "../../ctm/ChainCreationParamsLib.sol";

/// @notice The ecosystem (core) side of a registry-driven upgrade prepare, run before the CTM
///         prepare: deploys the new ecosystem implementations and pins them in a write-once
///         `CoreRegistry`. It emits NO governance calls of its own — the transition the CTM
///         prepare deploys names the registry, and `CTMUpgradeExecutor.stage1` applies it through
///         the bound ecosystem executor. Anything a version script still needs governance to do
///         is declared as an external action and listed in the output.
/// @dev Version scripts inherit and override; the v34 bootstrap edge overrides the object
///      deployment and declares every call of its one-time edge.
contract DefaultCoreUpgrade is Script, DeployL1CoreUtils {
    using stdToml for string;
    using ExternalActionsLib for ExternalActionsLib.Ledger;

    /// @notice The write-once inventory of this upgrade's ecosystem implementation swaps; zero
    ///         when the run deployed no ecosystem implementation.
    CoreRegistry public coreRegistry;

    /// @dev The governance/admin calls this prepare emits that the upgrade objects do not
    ///      describe (see {ExternalActionsLib}).
    ExternalActionsLib.Ledger internal externalActions;

    /// @notice Internal state of the upgrade script
    struct EcosystemUpgradeConfig {
        bool initialized;
        string outputPath;
    }

    struct AdditionalConfigParams {
        uint256 newProtocolVersion;
        bool hasPreV32IntrospectionOverride;
        bool usePreV32IntrospectionOverride;
    }
    AdditionalConfigParams internal additionalConfig;

    EcosystemUpgradeConfig internal upgradeConfig;

    /// @notice Single-call entry point invoked by the protocol-ops CLI's `upgrade-prepare-all`
    ///         (`ICoreUpgradeV31` in `contracts/script-interfaces/IUpgradeV31.sol`).
    function noGovernancePrepare(CoreUpgradeParams memory _params) public virtual {
        initializeWithArgs(
            _params.bridgehubProxyAddress,
            _params.create2FactorySalt,
            _params.upgradeInputPath,
            _params.outputPath
        );
        prepareEcosystemUpgrade();
        prepareDefaultGovernanceCalls();
    }

    function initializeWithArgs(
        address bridgehubProxyAddress,
        bytes32 create2FactorySalt,
        string memory upgradeInputPath,
        string memory _outputPath
    ) public virtual {
        string memory root = vm.projectRoot();
        upgradeInputPath = string.concat(root, upgradeInputPath);

        initializeConfigWithArgs(bridgehubProxyAddress, create2FactorySalt, upgradeInputPath);

        upgradeConfig.outputPath = string.concat(root, _outputPath);
        upgradeConfig.initialized = true;
    }

    /// @notice Full default upgrade preparation flow
    function prepareEcosystemUpgrade() public virtual {
        deployNewEcosystemContractsL1();
        console.log("Ecosystem contracts are deployed!");
        deployEcosystemUpgradeObjects();
        saveOutput(upgradeConfig.outputPath);
        console.log("Core upgrade output saved!");
    }

    /// @notice The upgrade objects of the ecosystem side. The default deploys the registry over the
    ///         implementations this run deployed; the bootstrap edge also deploys the executor.
    function deployEcosystemUpgradeObjects() public virtual {
        deployCoreRegistry();
    }

    /// @notice Deploys the write-once inventory of this upgrade's swaps — one source-checked row
    ///         per proxy this run deployed a new implementation for. Nothing is deployed when the
    ///         run deployed none (a CTM-only upgrade has no ecosystem leg).
    /// @dev Rides the CREATE2 factory like every prepare deployment: the Safe bundle replays factory
    ///      transactions only.
    function deployCoreRegistry() public virtual {
        ProxyUpgradeRow[] memory rows = _coreProxyUpgradeRows();
        uint256 participating = 0;
        uint256 length = rows.length;
        for (uint256 i = 0; i < length; ++i) {
            if (rows[i].implNew.addr != address(0)) {
                ++participating;
            }
        }
        if (participating == 0) {
            console.log("No ecosystem implementation deployed: this upgrade has no CoreRegistry");
            return;
        }
        coreRegistry = CoreRegistry(
            deployViaCreate2AndNotify(
                type(CoreRegistry).creationCode,
                abi.encode(CoreRegistryManifest({proxyUpgrades: rows})),
                "CoreRegistry"
            )
        );
    }

    /// @notice The enum-indexed ecosystem inventory: one slot per `L1EcosystemContract` member, a
    ///         source-checked row (live implementation read from the EIP-1967 slot) for every proxy
    ///         this run deployed a new implementation for, every other slot an explicit inert zero.
    function _coreProxyUpgradeRows() internal view virtual returns (ProxyUpgradeRow[] memory rows) {
        rows = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        rows[uint256(L1EcosystemContract.L1Bridgehub)] = _row(
            coreAddresses.bridgehub.proxies.bridgehub,
            coreAddresses.bridgehub.implementations.bridgehub
        );
        rows[uint256(L1EcosystemContract.L1Nullifier)] = _row(
            coreAddresses.bridges.proxies.l1Nullifier,
            coreAddresses.bridges.implementations.l1Nullifier
        );
        rows[uint256(L1EcosystemContract.L1AssetRouter)] = _row(
            coreAddresses.bridges.proxies.l1AssetRouter,
            coreAddresses.bridges.implementations.l1AssetRouter
        );
        rows[uint256(L1EcosystemContract.L1NativeTokenVault)] = _row(
            coreAddresses.bridges.proxies.l1NativeTokenVault,
            coreAddresses.bridges.implementations.l1NativeTokenVault
        );
        rows[uint256(L1EcosystemContract.L1MessageRoot)] = _row(
            coreAddresses.bridgehub.proxies.messageRoot,
            coreAddresses.bridgehub.implementations.messageRoot
        );
        rows[uint256(L1EcosystemContract.CTMDeploymentTracker)] = _row(
            coreAddresses.bridgehub.proxies.ctmDeploymentTracker,
            coreAddresses.bridgehub.implementations.ctmDeploymentTracker
        );
        rows[uint256(L1EcosystemContract.L1ChainAssetHandler)] = _row(
            coreAddresses.bridgehub.proxies.chainAssetHandler,
            coreAddresses.bridgehub.implementations.chainAssetHandler
        );
    }

    /// @dev The inert (all-zero) row when this run deployed no implementation for the proxy.
    function _row(address _proxy, address _implNew) internal view returns (ProxyUpgradeRow memory row) {
        if (_implNew == address(0)) {
            return row;
        }
        return
            ProxyUpgradeRow({
                proxy: _proxy,
                expectedOldImpl: Utils.getImplementation(_proxy),
                implNew: PinnedContract({addr: _implNew, codehash: _implNew.codehash}),
                callInitializeUpgrade: false,
                admin: ProxyAdmin(address(0))
            });
    }

    /// @notice Declares one governance/admin call this prepare emits that the upgrade objects do
    ///         not describe. Everything a version script adds to a stage goes through here, so
    ///         the output lists it (see {ExternalActionsLib}).
    function declareExternalAction(
        string memory _phase,
        string memory _label,
        string memory _authority,
        Call memory _call
    ) internal {
        externalActions.declare(_phase, _label, _authority, _call);
    }

    /// @notice One line per declared external action (see {ExternalActionsLib.describe}).
    function externalActionDescriptions() public view returns (string[] memory) {
        return externalActions.describe();
    }

    /// @notice Deploy everything that should be deployed
    function deployNewEcosystemContractsL1() public virtual {}

    function getOwnerAddress() public virtual returns (address) {
        return config.ownerAddress;
    }

    /// @notice The ecosystem's bound `EcosystemUpgradeExecutor`: the owner of the shared ecosystem
    ///         `ProxyAdmin` once the bootstrap edge has handed it over. The transition the CTM
    ///         prepare deploys runs this upgrade's ecosystem leg through it. The bootstrap prepare
    ///         overrides this with the executor it deploys.
    function getEcosystemUpgradeExecutor() public view virtual returns (address) {
        address admin = coreAddresses.shared.transparentProxyAdmin;
        require(admin != address(0), "ecosystem ProxyAdmin not discovered");
        address executor = ProxyAdmin(admin).owner();
        require(
            executor.code.length != 0,
            "ecosystem ProxyAdmin owner is not a contract: run the bootstrap edge first"
        );
        require(
            address(EcosystemUpgradeExecutor(payable(executor)).PROXY_ADMIN()) == admin,
            "ecosystem ProxyAdmin owner is not an executor bound to it"
        );
        return executor;
    }

    function setOwners(address owner) public virtual {
        config.ownerAddress = owner;
    }

    function getNewProtocolVersion() public virtual returns (uint256) {
        return additionalConfig.newProtocolVersion;
    }

    function getProtocolUpgradeNonce() public virtual returns (uint256) {
        return (getNewProtocolVersion() >> 32);
    }

    function getOldProtocolDeadline() public virtual returns (uint256) {
        // Returns max deadline initially. After the upgrade is complete (stage2),
        // governance should call setNewVersionUpgrade with deadline=0 to force
        // all chains to upgrade immediately.
        return type(uint256).max;
    }

    function getDiscoveredBridgehub() public view returns (BridgehubAddresses memory) {
        return coreAddresses.bridgehub;
    }

    function getCoreAddresses() public view returns (CoreDeployedAddresses memory) {
        return coreAddresses;
    }

    function initializeConfigWithArgs(
        address bridgehubProxyAddress,
        bytes32 create2FactorySalt,
        string memory upgradeInputPath
    ) public virtual {
        string memory upgradeToml = vm.readFile(upgradeInputPath);

        // Only override the salt when explicitly provided (non-zero).
        // When zero, the script falls back to the CREATE2_FACTORY_SALT env var or built-in default.
        if (create2FactorySalt != bytes32(0)) {
            setCreate2Salt(create2FactorySalt);
        }

        // Only ZKsync OS ecosystems can be upgraded onto this release.

        // Optional override for pre-v32 introspection selection. Autodetection reads the protocol version of
        // a registered chain, which lags the L1 contracts: an ecosystem whose core contracts are already v32
        // while its chains have not upgraded yet (mid-upgrade, or a fixture deployed from current code with a
        // v31 genesis) must state so here.
        if (upgradeToml.keyExists("$.pre_v32_introspection")) {
            additionalConfig.hasPreV32IntrospectionOverride = true;
            additionalConfig.usePreV32IntrospectionOverride = upgradeToml.readBool("$.pre_v32_introspection");
        }

        // Protocol version comes from genesis config
        additionalConfig.newProtocolVersion = loadProtocolVersionFromGenesis();

        // Legacy Era gateway chain ID — baked into L1MessageRoot as immutable
        // ERA_GATEWAY_CHAIN_ID. Read from the upgrade input TOML ([legacy_gateway] section)
        // so the constructor gets the right value. Optional: absent on fresh/local.
        if (upgradeToml.keyExists("$.legacy_gateway.chain_id")) {
            config.legacyGatewayChainId = upgradeToml.readUint("$.legacy_gateway.chain_id");
        }

        coreAddresses.bridgehub.proxies.bridgehub = bridgehubProxyAddress;
        require(coreAddresses.bridgehub.proxies.bridgehub != address(0), "bridgehub_proxy_addr is zero");
        setAddressesBasedOnBridgehub();
        initializeL1CoreUtilsConfig();
    }

    function initializeL1CoreUtilsConfig() internal virtual {
        L1AssetRouter assetRouter = L1AssetRouter(coreAddresses.bridges.proxies.l1AssetRouter);
        L1Bridgehub bridgehub = L1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub);
        Governance governance = Governance(payable(coreAddresses.shared.governance));
        config.l1ChainId = block.chainid;
        config.deployerAddress = getBroadcasterAddress();
        config.ownerAddress = assetRouter.owner();

        config.contracts.governanceSecurityCouncilAddress = governance.securityCouncil();

        config.contracts.maxNumberOfChains = bridgehub.MAX_NUMBER_OF_ZK_CHAINS();

        config.tokens.tokenWethAddress = assetRouter.L1_WETH_TOKEN();
    }

    function setAddressesBasedOnBridgehub() internal virtual {
        address bridgehubProxy = coreAddresses.bridgehub.proxies.bridgehub;

        bool preV32Ecosystem;
        if (additionalConfig.hasPreV32IntrospectionOverride) {
            preV32Ecosystem = additionalConfig.usePreV32IntrospectionOverride;
        } else if (!AddressIntrospector.hasRegisteredChains(bridgehubProxy)) {
            // A chainless ecosystem has no protocol version to inspect. It cannot have been upgraded into
            // existence either, so it was deployed from scratch with the current contracts.
            preV32Ecosystem = false;
        } else {
            preV32Ecosystem = AddressIntrospector.shouldUsePreV32Introspection(bridgehubProxy);
        }

        if (preV32Ecosystem) {
            // v31 ecosystem: the nullifier has no `l1InteropHandler` getter yet, so the discovered
            // address stays zero and the upgrade deploys the handler itself.
            coreAddresses = AddressIntrospector.getCoreDeployedAddressesV31(bridgehubProxy);
        } else {
            coreAddresses = AddressIntrospector.getCoreDeployedAddresses(bridgehubProxy);
        }
    }

    function saveOutput(string memory outputPath) internal virtual {
        // Serialize bridgehub addresses
        vm.serializeAddress("bridgehub", "bridgehub_proxy_addr", coreAddresses.bridgehub.proxies.bridgehub);
        vm.serializeAddress(
            "bridgehub",
            "bridgehub_implementation_addr",
            coreAddresses.bridgehub.implementations.bridgehub
        );
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_implementation_addr",
            coreAddresses.bridgehub.implementations.ctmDeploymentTracker
        );
        vm.serializeAddress(
            "bridgehub",
            "ctm_deployment_tracker_proxy_addr",
            coreAddresses.bridgehub.proxies.ctmDeploymentTracker
        );
        vm.serializeAddress(
            "bridgehub",
            "chain_asset_handler_implementation_addr",
            coreAddresses.bridgehub.implementations.chainAssetHandler
        );
        vm.serializeAddress(
            "bridgehub",
            "chain_asset_handler_proxy_addr",
            coreAddresses.bridgehub.proxies.chainAssetHandler
        );
        if (coreAddresses.bridgehub.proxies.chainRegistrationSender != address(0)) {
            vm.serializeAddress(
                "bridgehub",
                "chain_registration_sender_proxy_addr",
                coreAddresses.bridgehub.proxies.chainRegistrationSender
            );
            // A registry-driven prepare redeploys only what its release changes.
            if (coreAddresses.bridgehub.implementations.chainRegistrationSender != address(0)) {
                vm.serializeAddress(
                    "bridgehub",
                    "chain_registration_sender_implementation_addr",
                    coreAddresses.bridgehub.implementations.chainRegistrationSender
                );
            }
        }
        vm.serializeAddress("bridgehub", "message_root_proxy_addr", coreAddresses.bridgehub.proxies.messageRoot);
        string memory bridgehubSerialized = vm.serializeAddress(
            "bridgehub",
            "message_root_implementation_addr",
            coreAddresses.bridgehub.implementations.messageRoot
        );

        // Serialize bridges addresses
        vm.serializeAddress("bridges", "l1_nullifier_proxy_addr", coreAddresses.bridges.proxies.l1Nullifier);
        vm.serializeAddress(
            "bridges",
            "l1_nullifier_implementation_addr",
            coreAddresses.bridges.implementations.l1Nullifier
        );
        vm.serializeAddress(
            "bridges",
            "l1_asset_router_implementation_addr",
            coreAddresses.bridges.implementations.l1AssetRouter
        );
        vm.serializeAddress("bridges", "l1_asset_router_proxy_addr", coreAddresses.bridges.proxies.l1AssetRouter);
        // TODO: legacy name
        vm.serializeAddress(
            "bridges",
            "shared_bridge_implementation_addr",
            coreAddresses.bridges.implementations.l1AssetRouter
        );
        vm.serializeAddress(
            "bridges",
            "bridged_standard_erc20_impl",
            coreAddresses.bridges.bridgedStandardERC20Implementation
        );
        // Same keys as the from-scratch deployment writes, so downstream tooling reads one shape.
        vm.serializeAddress(
            "bridges",
            "l1_interop_handler_implementation_addr",
            coreAddresses.bridges.implementations.l1InteropHandler
        );
        vm.serializeAddress("bridges", "l1_interop_handler_proxy_addr", coreAddresses.bridges.proxies.l1InteropHandler);

        string memory bridgesSerialized = vm.serializeAddress(
            "bridges",
            "bridged_token_beacon",
            coreAddresses.bridges.bridgedTokenBeacon
        );

        vm.serializeString("deployed_addresses", "bridgehub", bridgehubSerialized);
        vm.serializeString("deployed_addresses", "bridges", bridgesSerialized);
        vm.serializeAddress(
            "deployed_addresses",
            "native_token_vault_addr",
            coreAddresses.bridges.proxies.l1NativeTokenVault
        );
        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "native_token_vault_implementation_addr",
            coreAddresses.bridges.implementations.l1NativeTokenVault
        );

        string memory shared = vm.serializeAddress(
            "shared",
            "transparent_proxy_admin",
            coreAddresses.shared.transparentProxyAdmin
        );
        deployedAddresses = vm.serializeString("deployed_addresses", "shared", shared);

        string memory misc = vm.serializeAddress("misc", "deployer_addr", config.deployerAddress);
        vm.serializeString("root", "upgrade_addresses", deployedAddresses);
        // The objects the CTM prepare and reviewers take from this run.
        vm.serializeAddress("registry", "core_registry_addr", address(coreRegistry));
        string memory registry = vm.serializeAddress(
            "registry",
            "ecosystem_upgrade_executor_addr",
            getEcosystemUpgradeExecutor()
        );
        vm.serializeString("root", "registry", registry);
        string memory toml = vm.serializeString("root", "misc", misc);

        vm.writeToml(toml, outputPath);

        saveOutputVersionSpecific();
    }

    function saveOutputVersionSpecific() public virtual {}

    ////////////////////////////// Preparing calls /////////////////////////////////

    function prepareDefaultGovernanceCalls()
        public
        virtual
        returns (Call[] memory stage0Calls, Call[] memory stage1Calls, Call[] memory stage2Calls)
    {
        // The ecosystem side emits only what a version script declared as external actions: the
        // recurring ecosystem leg rides the CTM executor's stage calls.
        stage0Calls = prepareStage0GovernanceCalls();
        vm.serializeBytes("governance_calls", "stage0_calls", abi.encode(stage0Calls));
        stage1Calls = prepareStage1GovernanceCalls();
        vm.serializeBytes("governance_calls", "stage1_calls", abi.encode(stage1Calls));
        stage2Calls = prepareStage2GovernanceCalls();

        string memory governanceCallsSerialized = vm.serializeBytes(
            "governance_calls",
            "stage2_calls",
            abi.encode(stage2Calls)
        );

        // Upstream forge's keyed `vm.writeToml(json, path, key)` silently no-ops when the key
        // does not exist in the file yet, so append sections by re-serializing into the same
        // "root" object and rewriting the whole file instead.
        vm.serializeString("root", "external_actions", externalActionDescriptions());
        string memory updatedToml = vm.serializeString("root", "governance_calls", governanceCallsSerialized);
        vm.writeToml(updatedToml, upgradeConfig.outputPath);
    }

    /// @notice The governance stages of the ecosystem side: nothing but the declared external
    ///         actions of each phase. The recurring ecosystem leg — the registry applied through
    ///         the bound ecosystem executor — is `CTMUpgradeExecutor.stage1`'s job, ordered and
    ///         enforced on-chain.
    function prepareStage0GovernanceCalls() public virtual returns (Call[] memory calls) {
        return externalActions.callsForPhase(ExternalActionsLib.PHASE_STAGE_0);
    }

    function prepareStage1GovernanceCalls() public virtual returns (Call[] memory calls) {
        return externalActions.callsForPhase(ExternalActionsLib.PHASE_STAGE_1);
    }

    function prepareStage2GovernanceCalls() public virtual returns (Call[] memory calls) {
        return externalActions.callsForPhase(ExternalActionsLib.PHASE_STAGE_2);
    }

    // add this to be excluded from coverage report

    /// @notice Load protocol version from genesis config
    function loadProtocolVersionFromGenesis() internal virtual returns (uint256) {
        string memory genesisPath = Utils.genesisConfigPath();
        return ChainCreationParamsLib.getChainCreationParams(genesisPath).latestProtocolVersion;
    }

    function getBroadcasterAddress() internal view virtual returns (address) {
        return tx.origin;
    }

    function test() internal override {}
}
