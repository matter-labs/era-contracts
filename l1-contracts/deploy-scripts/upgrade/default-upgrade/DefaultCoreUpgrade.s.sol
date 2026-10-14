// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2 as console} from "forge-std/Script.sol";

import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {Call} from "contracts/governance/Common.sol";

import {DeployL1CoreUtils} from "../../ecosystem/DeployL1CoreUtils.s.sol";

import {Governance} from "contracts/governance/Governance.sol";
import {CoreTransition} from "contracts/upgrades/registry/objects/CoreTransition.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {CoreTransitionManifest, ProxyUpgradeRow} from "contracts/upgrades/registry/RegistryTypes.sol";
import {
    L1EcosystemContract,
    L1_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {BridgehubAddresses} from "../../utils/Types.sol";

import {AddressIntrospector} from "../../utils/AddressIntrospector.sol";
import {CoreUpgradeParams} from "./UpgradeParams.sol";
import {BytecodeUtils} from "../../utils/bytecode/BytecodeUtils.s.sol";
import {ExternalActionsLib} from "./ExternalActionsLib.sol";
import {ReleaseMemberProbe} from "./ReleaseMemberProbe.sol";
import {Utils} from "../../utils/Utils.sol";

/// @notice The ecosystem (core) side of a registry-driven upgrade prepare, run before the CTM
///         prepare: deploys every ecosystem implementation whose code differs from the live one
///         (and reuses the rest) and pins the swaps in a write-once `CoreTransition`. It emits NO
///         governance calls of its own — the operation the CTM prepare deploys names the core
///         transition, and the coordinator's stage 1 applies it through the `CoreUpgradeExecutor`.
///         Anything a version script still needs governance to do is declared as an external
///         action and listed in the output.
/// @dev Version scripts inherit and declare what they change ({changedEcosystemImplementations});
///      the v35 bootstrap edge also deploys the executors.
contract DefaultCoreUpgrade is Script, DeployL1CoreUtils {
    using stdToml for string;
    using ExternalActionsLib for ExternalActionsLib.Ledger;

    /// @notice The write-once inventory of this upgrade's ecosystem implementation swaps; zero
    ///         when the run deployed no ecosystem implementation.
    CoreTransition public coreTransition;

    /// @dev The governance/admin calls this prepare emits that the upgrade objects do not
    ///      describe (see {ExternalActionsLib}).
    ExternalActionsLib.Ledger internal externalActions;

    /// @dev Deployed on first use; see {ReleaseMemberProbe} for why it is a separate contract.
    ReleaseMemberProbe internal implementationProbe;

    /// @notice Internal state of the upgrade script
    struct EcosystemUpgradeConfig {
        bool initialized;
        string outputPath;
    }

    EcosystemUpgradeConfig internal upgradeConfig;

    /// @notice Single-call entry point invoked by the protocol-ops CLI's `upgrade-prepare-all`
    ///         (`ICoreUpgradePrepare` in `contracts/script-interfaces/IUpgradePrepare.sol`).
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

    /// @notice The upgrade objects of the ecosystem side. The default deploys the core transition over the
    ///         implementations this run deployed; the bootstrap edge also deploys the executor.
    function deployEcosystemUpgradeObjects() public virtual {
        deployCoreTransition();
    }

    /// @notice Deploys the write-once inventory of this upgrade's swaps — one source-checked row
    ///         per proxy this run deployed a new implementation for. Nothing is deployed when the
    ///         run deployed none (a CTM-only upgrade has no ecosystem leg).
    /// @dev Rides the CREATE2 factory like every prepare deployment: the Safe bundle replays factory
    ///      transactions only.
    function deployCoreTransition() public virtual {
        ProxyUpgradeRow[] memory rows = _coreProxyUpgradeRows();
        _requireDeployedImplementationsInstalled(rows);
        uint256 participating = 0;
        uint256 length = rows.length;
        for (uint256 i = 0; i < length; ++i) {
            if (rows[i].implNew != address(0)) {
                ++participating;
            }
        }
        if (participating == 0) {
            console.log("No ecosystem implementation deployed: this upgrade has no CoreTransition");
            return;
        }
        // From the build ARTIFACT, so a reviewer's own build of the same commit reproduces the
        // creation code this object's address is re-derived from.
        coreTransition = CoreTransition(
            deployViaCreate2AndNotify(
                BytecodeUtils.readBytecodeL1("CoreTransition.sol", "CoreTransition"),
                abi.encode(CoreTransitionManifest({proxyUpgrades: rows})),
                "CoreTransition"
            )
        );
    }

    /// @notice The enum-indexed ecosystem inventory: one slot per `L1EcosystemContract` member, a
    ///         source-checked row (live implementation read from the EIP-1967 slot) for every proxy
    ///         this run deployed a new implementation for, every other slot an explicit inert zero.
    /// @dev `L1InteropHandler` and `ChainRegistrationSender` have no row builder, so no prepare
    ///      deploys or installs them (TODO(EVM-1644): decide whether the sender is refreshed).
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
    ///      Discovery fills `implementations` from the LIVE EIP-1967 slots, so "a new
    ///      implementation" is the one that DIFFERS from what the proxy already runs — an
    ///      implementation equal to the live one is the slot the version left alone, not a swap of
    ///      a contract onto itself.
    function _row(address _proxy, address _implNew) internal view returns (ProxyUpgradeRow memory row) {
        if (_implNew == address(0)) {
            return row;
        }
        address liveImpl = Utils.getImplementation(_proxy);
        if (_implNew == liveImpl) {
            return row;
        }
        return
            ProxyUpgradeRow({
                proxy: _proxy,
                expectedOldImpl: liveImpl,
                implNew: _implNew,
                callInitializeUpgrade: false
            });
    }

    /// @notice Refuses an ORPHANED deployment: an ecosystem implementation this run produced that
    ///         the inventory does not install. A deployment nothing references is either a swap that
    ///         silently will not ship or a row builder that was never written, and both look
    ///         exactly like a successful prepare from the output alone.
    function _requireDeployedImplementationsInstalled(ProxyUpgradeRow[] memory _rows) internal view {
        address[] memory deployed = _deployedCoreImplementations();
        uint256 length = deployed.length;
        for (uint256 i = 0; i < length; ++i) {
            require(
                deployed[i] == address(0) || _rows[i].implNew == deployed[i],
                // solhint-disable-next-line func-named-parameters
                string.concat(
                    "orphaned ecosystem deployment at inventory slot ",
                    vm.toString(i),
                    " (",
                    vm.toString(deployed[i]),
                    "): this run deployed it but the CoreTransition does not install it. Add its row to "
                    "`_coreProxyUpgradeRows()`."
                )
            );
        }
    }

    /// @dev The implementations THIS RUN produced, over the same slot space as
    ///      {_coreProxyUpgradeRows} so the orphan check compares like with like: an entry is set
    ///      only where the address differs from the proxy's live implementation (discovery fills
    ///      the struct from live, see {_row}).
    function _deployedCoreImplementations() private view returns (address[] memory impls) {
        impls = new address[](L1_ECOSYSTEM_CONTRACT_COUNT);
        impls[uint256(L1EcosystemContract.L1Bridgehub)] = _deployedImpl(
            coreAddresses.bridgehub.proxies.bridgehub,
            coreAddresses.bridgehub.implementations.bridgehub
        );
        impls[uint256(L1EcosystemContract.L1ChainAssetHandler)] = _deployedImpl(
            coreAddresses.bridgehub.proxies.chainAssetHandler,
            coreAddresses.bridgehub.implementations.chainAssetHandler
        );
        impls[uint256(L1EcosystemContract.L1MessageRoot)] = _deployedImpl(
            coreAddresses.bridgehub.proxies.messageRoot,
            coreAddresses.bridgehub.implementations.messageRoot
        );
        impls[uint256(L1EcosystemContract.L1Nullifier)] = _deployedImpl(
            coreAddresses.bridges.proxies.l1Nullifier,
            coreAddresses.bridges.implementations.l1Nullifier
        );
        impls[uint256(L1EcosystemContract.L1AssetRouter)] = _deployedImpl(
            coreAddresses.bridges.proxies.l1AssetRouter,
            coreAddresses.bridges.implementations.l1AssetRouter
        );
        impls[uint256(L1EcosystemContract.L1NativeTokenVault)] = _deployedImpl(
            coreAddresses.bridges.proxies.l1NativeTokenVault,
            coreAddresses.bridges.implementations.l1NativeTokenVault
        );
        impls[uint256(L1EcosystemContract.L1InteropHandler)] = _deployedImpl(
            coreAddresses.bridges.proxies.l1InteropHandler,
            coreAddresses.bridges.implementations.l1InteropHandler
        );
        impls[uint256(L1EcosystemContract.CTMDeploymentTracker)] = _deployedImpl(
            coreAddresses.bridgehub.proxies.ctmDeploymentTracker,
            coreAddresses.bridgehub.implementations.ctmDeploymentTracker
        );
        impls[uint256(L1EcosystemContract.ChainRegistrationSender)] = _deployedImpl(
            coreAddresses.bridgehub.proxies.chainRegistrationSender,
            coreAddresses.bridgehub.implementations.chainRegistrationSender
        );
    }

    /// @dev `_impl` when it is a REPLACEMENT this run produced, zero otherwise: zero when the
    ///      address is what the proxy already runs, and zero when there is no proxy at all — an
    ///      implementation for a proxy that does not exist yet cannot be installed by a row, so it
    ///      is not a replacement this check can hold anyone to.
    function _deployedImpl(address _proxy, address _impl) private view returns (address) {
        if (_impl == address(0) || _proxy == address(0)) {
            return address(0);
        }
        return _impl == Utils.getImplementation(_proxy) ? address(0) : _impl;
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

    /// @notice The declared external actions as the output's `external_actions` list (see
    ///         {ExternalActionsLib.serialize}).
    function externalActionEntries() public returns (string[] memory) {
        return externalActions.serialize();
    }

    /// @notice Deploys every ecosystem implementation the inventory can install
    ///         ({_coreProxyUpgradeRows}) whose code differs from the live one, and reuses the rest.
    function deployNewEcosystemContractsL1() public virtual {
        BridgehubAddresses storage bridgehubAddresses = coreAddresses.bridgehub;
        bridgehubAddresses.implementations.bridgehub = _deployEcosystemImplementation(
            "L1Bridgehub",
            bridgehubAddresses.proxies.bridgehub
        );
        bridgehubAddresses.implementations.messageRoot = _deployEcosystemImplementation(
            "L1MessageRoot",
            bridgehubAddresses.proxies.messageRoot
        );
        bridgehubAddresses.implementations.ctmDeploymentTracker = _deployEcosystemImplementation(
            "CTMDeploymentTracker",
            bridgehubAddresses.proxies.ctmDeploymentTracker
        );
        bridgehubAddresses.implementations.chainAssetHandler = _deployEcosystemImplementation(
            "L1ChainAssetHandler",
            bridgehubAddresses.proxies.chainAssetHandler
        );
        coreAddresses.bridges.implementations.l1Nullifier = _deployEcosystemImplementation(
            "L1Nullifier",
            coreAddresses.bridges.proxies.l1Nullifier
        );
        coreAddresses.bridges.implementations.l1AssetRouter = _deployEcosystemImplementation(
            "L1AssetRouter",
            coreAddresses.bridges.proxies.l1AssetRouter
        );
        coreAddresses.bridges.implementations.l1NativeTokenVault = _deployEcosystemImplementation(
            "L1NativeTokenVault",
            coreAddresses.bridges.proxies.l1NativeTokenVault
        );
    }

    /// @notice The ecosystem implementations this version SETS OUT to change, by `deploySimpleContract`
    ///         name. The prepare refuses to replace a live implementation not named here — the same
    ///         rule as `DefaultCTMUpgrade.changedReleaseMembers`, for the same reason. Empty by
    ///         default: a version that changes no ecosystem contract reuses all of them.
    function changedEcosystemImplementations() internal view virtual returns (string[] memory) {
        return new string[](0);
    }

    /// @notice The implementation `_proxy` runs after this upgrade: its live one when that already
    ///         runs the code the current sources produce, a fresh deployment otherwise.
    function _deployEcosystemImplementation(string memory _name, address _proxy) internal returns (address) {
        if (_proxy == address(0)) {
            return address(0);
        }
        address live = Utils.getImplementation(_proxy);
        if (_canReuseEcosystemImplementation(_name, live)) {
            console.log("Ecosystem implementation unchanged, reusing:", _name, live);
            return live;
        }
        _requireDeclaredEcosystemChange(_name, live);
        console.log("Ecosystem implementation changed by this version, replacing:", _name, live);
        return deploySimpleContract(_name);
    }

    /// @notice Whether the live `_live` already runs the code `_name` deploys with this run's
    ///         constructor arguments (runtime codehash, immutables included; see {ReleaseMemberProbe}).
    /// @dev Virtual so a fixture whose live ecosystem was deployed from the current sources can
    ///      simulate the older build a production edge departs from.
    function _canReuseEcosystemImplementation(string memory _name, address _live) internal virtual returns (bool) {
        if (_live == address(0) || _live.code.length == 0) {
            return false;
        }
        if (address(implementationProbe) == address(0)) {
            // Plain CREATE, never broadcast: it lives only inside this run's simulation.
            implementationProbe = new ReleaseMemberProbe();
        }
        return _live.codehash == implementationProbe.codehashOf(_name, getCreationCalldata(_name));
    }

    /// @notice Refuses a replacement this version did not declare (see
    ///         {changedEcosystemImplementations}).
    function _requireDeclaredEcosystemChange(string memory _name, address _live) internal view {
        if (_live == address(0) || _live.code.length == 0) {
            return;
        }
        string[] memory declared = changedEcosystemImplementations();
        uint256 length = declared.length;
        for (uint256 i = 0; i < length; ++i) {
            if (compareStrings(declared[i], _name)) {
                return;
            }
        }
        console.log("Undeclared ecosystem implementation change:", _name);
        console.log("  live:", _live);
        console.logBytes32(_live.codehash);
        require(
            false,
            string.concat(
                "ecosystem implementation '",
                _name,
                "' would be replaced but this version does not declare it as changed. Either add it to "
                "`changedEcosystemImplementations()`, or the local build differs from the one that produced "
                "the live code."
            )
        );
    }

    function getOwnerAddress() public virtual returns (address) {
        return config.ownerAddress;
    }

    /// @notice The ecosystem's lifecycle coordinator (`EcosystemUpgradeExecutor`), read from the
    ///         core executor once the bootstrap edge has bound them: the operation naming this
    ///         upgrade's transitions is driven through it, and every transition's timer is bound
    ///         to it. The bootstrap prepare overrides this with the coordinator it deploys.
    function getEcosystemUpgradeExecutor() public view virtual returns (address) {
        address coordinator = getCoreUpgradeExecutor().coordinator();
        require(coordinator != address(0), "core executor is not bound to a coordinator: run the bootstrap edge first");
        return coordinator;
    }

    /// @notice The ecosystem's `CoreUpgradeExecutor`: the owner of the shared ecosystem `ProxyAdmin`
    ///         once the bootstrap edge has handed it over. The bootstrap prepare overrides this
    ///         with the executor it deploys.
    function getCoreUpgradeExecutor() public view virtual returns (CoreUpgradeExecutor) {
        address admin = coreAddresses.shared.transparentProxyAdmin;
        require(admin != address(0), "ecosystem ProxyAdmin not discovered");
        address executor = ProxyAdmin(admin).owner();
        require(
            executor.code.length != 0,
            "ecosystem ProxyAdmin owner is not a contract: run the bootstrap edge first"
        );
        require(
            address(CoreUpgradeExecutor(payable(executor)).PROXY_ADMIN()) == admin,
            "ecosystem ProxyAdmin owner is not an executor bound to it"
        );
        return CoreUpgradeExecutor(payable(executor));
    }

    function getDiscoveredBridgehub() public view returns (BridgehubAddresses memory) {
        return coreAddresses.bridgehub;
    }

    function initializeConfigWithArgs(
        address bridgehubProxyAddress,
        bytes32 create2FactorySalt,
        string memory upgradeInputPath
    ) public virtual {
        // The core half reads no key from the upgrade input, but the input is still required to exist so
        // that a mistyped path fails here rather than in the CTM half.
        require(vm.isFile(upgradeInputPath), "upgrade input not found");

        // Only override the salt when explicitly provided (non-zero).
        // When zero, the script falls back to the CREATE2_FACTORY_SALT env var or built-in default.
        if (create2FactorySalt != bytes32(0)) {
            setCreate2Salt(create2FactorySalt);
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

        coreAddresses = AddressIntrospector.getCoreDeployedAddresses(bridgehubProxy);
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
        vm.serializeAddress("registry", "core_transition_addr", address(coreTransition));
        vm.serializeAddress("registry", "core_upgrade_executor_addr", address(getCoreUpgradeExecutor()));
        string memory registry = vm.serializeAddress(
            "registry",
            "ecosystem_upgrade_executor_addr",
            getEcosystemUpgradeExecutor()
        );
        vm.serializeString("root", "registry", registry);
        string memory toml = vm.serializeString("root", "misc", misc);

        vm.writeToml(toml, outputPath);
    }

    ////////////////////////////// Preparing calls /////////////////////////////////

    function prepareDefaultGovernanceCalls()
        public
        virtual
        returns (Call[] memory stage0Calls, Call[] memory stage1Calls, Call[] memory stage2Calls)
    {
        // The ecosystem side emits only what a version script declared as external actions: the
        // recurring ecosystem leg rides the coordinator's stage calls.
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
        vm.serializeString("root", "external_actions", externalActionEntries());
        string memory updatedToml = vm.serializeString("root", "governance_calls", governanceCallsSerialized);
        vm.writeToml(updatedToml, upgradeConfig.outputPath);
    }

    /// @notice The governance stages of the ecosystem side: nothing but the declared external
    ///         actions of each phase. The recurring ecosystem leg — the core transition applied through
    ///         the `CoreUpgradeExecutor` — is the coordinator's stage-1 job, ordered and enforced
    ///         on-chain.
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

    function getBroadcasterAddress() internal view virtual returns (address) {
        return tx.origin;
    }

    function test() internal override {}
}
