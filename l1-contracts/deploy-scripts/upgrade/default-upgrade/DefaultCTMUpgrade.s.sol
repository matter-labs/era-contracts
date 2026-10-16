// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// TODO(EVM-1644): LEGACY UPGRADE PROCESS — remove once the registry-driven upgrade process
// (contracts/upgrades/registry: EcosystemUpgradeExecutor coordinating CoreUpgradeExecutor /
// CTMUpgradeExecutor + release/transition registries) has fully replaced off-chain
// governance-calldata generation. Kept for the v35 bootstrap edge, which still ships a
// script-declared governance bundle (the committed cut itself is already facet-less; only the call
// orchestration remains script-composed).

import {Script, console2 as console} from "forge-std/Script.sol";

import {stdToml} from "forge-std/StdToml.sol";

import {Utils} from "../../utils/Utils.sol";
import {ChainCreationParamsConfig, ZkChainAddresses} from "../../utils/Types.sol";
import {StateTransitionContracts} from "contracts/common/StateTransitionTypes.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";

import {Governance} from "contracts/governance/Governance.sol";

import {Call} from "contracts/governance/Common.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";

import {CTMDeployedAddresses} from "../../ctm/DeployCTMUtils.s.sol";

import {BytecodePublisher} from "../../utils/bytecode/BytecodePublisher.s.sol";
import {SystemContractsProcessing} from "../SystemContractsProcessing.s.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {IValidatorTimelock} from "contracts/state-transition/validators/interfaces/IValidatorTimelock.sol";

import {AddressIntrospector} from "../../utils/AddressIntrospector.sol";
import {DeployCTMScript} from "../../ctm/DeployCTM.s.sol";
import {BytecodeUtils} from "../../utils/bytecode/BytecodeUtils.s.sol";
import {ReleaseMemberProbe} from "./ReleaseMemberProbe.sol";
import {UpgradeHelperLib} from "./UpgradeHelperLib.sol";
import {CTMUpgradeParams, UpgradeKind} from "./UpgradeParams.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol";
import {
    AuthoredL2Plan,
    OperationManifest,
    ProxyUpgradeRow,
    TransitionManifest
} from "contracts/upgrades/registry/RegistryTypes.sol";
import {CTM_CONTRACT_COUNT, CTMContract} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {ExternalActionsLib} from "./ExternalActionsLib.sol";

/// @notice The L2 side a version authors for its edge: the plan's authored input and the deployed
///         bytecodes to publish. The registry objects construct the L2 payload on-chain from what
///         they pin (see {docs/registry-driven-upgrades.md}); a prepare supplies only what a
///         release table cannot express — and, since a hash cannot supply its own preimage, the
///         bytecodes behind the plan, loaded from the build artifacts.
/// @param plan The authored input ({AuthoredL2Plan}): the delegate's and any extra bytecode info,
///        the pinned composer. The object constructs the addresses and factory dependencies.
/// @param factoryDependencies The deployed bytecodes the composed L2 transaction installs or
///        needs the sequencer to hold the preimage of: the delegate's and extras' code, the
///        table-derived deployments' code, and whatever the delegate deploys at execution. The
///        object refuses to commit until every factory dependency it constructs is published.
struct AuthoredL2Side {
    AuthoredL2Plan plan;
    bytes[] factoryDependencies;
}

/// @notice The CTM side of a registry-driven upgrade prepare, run after the core prepare: deploys
///         the new release (facets, DiamondInit, verifier, upgrade engine) and pins the edge in a
///         write-once `CTMTransition`, then the `EcosystemUpgradeOperation` associating that
///         transition with the core prepare's `CoreTransition`. It emits NO executor call of its
///         own: the governance call is `EcosystemUpgradeExecutor.execute(operation)`, derived by the
///         merge from the operation's address; anything a version script still needs governance (or
///         an admin) to do is declared as an external action and listed in the output.
/// @dev Version scripts inherit and override; the v35 bootstrap edge deploys no transition and
///      declares every call of its one-time edge instead.
contract DefaultCTMUpgrade is Script, DeployCTMScript {
    using stdToml for string;
    using ExternalActionsLib for ExternalActionsLib.Ledger;

    /// @dev Deployed on first use; see {ReleaseMemberProbe} for why it is a separate contract.
    ReleaseMemberProbe internal releaseMemberProbe;

    struct UpgradeDeployedAddresses {
        /// @dev The bootstrap edge's coordinator input (`CTMUpgradeParams.ecosystemUpgradeExecutor`);
        ///      every later edge reads it off-chain from the CTM through {upgradeCoordinator}.
        address ecosystemUpgradeExecutor;
        /// @dev The core prepare's ecosystem inventory (an input, see `CTMUpgradeParams`): the
        ///      operation's ecosystem leg, and the bootstrap edge's second object.
        address coreTransition;
        /// @dev The write-once transition this prepare deploys (zero for the bootstrap edge).
        address ctmTransition;
        /// @dev The write-once operation over `{coreTransition, ctmTransition}` this prepare
        ///      deploys — what the coordinator's `execute` call names (zero for the bootstrap
        ///      edge, which has no transition to compose over).
        address ecosystemUpgradeOperation;
        /// @dev The engine this edge commits, held only until the object that pins it exists.
        ///      Read it through {committedUpgradeEngine}, never directly.
        address upgradeEngine;
    }

    struct AdditionalConfig {
        address ctm;
        uint256 oldProtocolVersion;
    }

    /// @notice Internal state of the upgrade script
    struct EcosystemUpgradeConfig {
        bool initialized;
        bool l2SidePrepared;
        // TODO set it based on version of the BRIDGEHUB before upgrade

        bool ecosystemContractsDeployed;
        string outputPath;
    }

    struct PermanentCTMConfig {
        bytes32 create2FactorySalt;
        address ctmProxy;
        /// @dev ZK token asset ID, used by `InteropCenter.initL2` for fixed-fee bundles.
        ///      MUST be non-zero — `InteropCenter.initL2` reverts otherwise, which would abort the
        ///      L2 upgrade transaction.
        bytes32 zkTokenAssetId;
        /// @dev Whether the CTM's verifier is the testnet one, which accepts unproven batches.
        ///      Declared per environment in `upgrade-envs/permanent-values/<env>.toml` (true for
        ///      every env except mainnet) and cross-checked against the env by the protocol-ops
        ///      verifier. Not introspected off the deployed verifier: pre-v34 production verifiers
        ///      export no flag, so probing would need the staticcall this repo forbids.
        bool testnetVerifier;
    }

    // The output of the script
    UpgradeDeployedAddresses internal upgradeAddresses;
    EcosystemUpgradeConfig internal upgradeConfig;

    // Input for the script
    AdditionalConfig internal newConfig;

    // Discovered addresses
    ZkChainAddresses internal discoveredRepresentativeZkChain;
    ZkChainAddresses internal upToDateZkChain;
    L1Bridgehub internal bridgehub;

    /// @dev The authored L2 plan of this edge with its factory dependencies published and pinned,
    ///      stored as its ABI encoding (the legacy codegen pipeline cannot copy a struct array with
    ///      dynamic members into storage). Read through {authoredL2Plan}.
    bytes internal encodedAuthoredL2Plan;

    /// @dev The governance/admin calls this prepare emits that the upgrade objects do not
    ///      describe (see {ExternalActionsLib}).
    ExternalActionsLib.Ledger internal externalActions;

    /// @notice Single-call entry point invoked by the protocol-ops CLI's `upgrade-prepare-all`,
    ///         once per CTM proxy (`ICTMUpgradePrepare` in `contracts/script-interfaces/IUpgradePrepare.sol`).
    function noGovernancePrepare(CTMUpgradeParams memory _params) public virtual {
        initializeWithArgs({
            ctmProxy: _params.ctmProxy,
            rollupDAManager: _params.rollupDAManager,
            create2FactorySalt: _params.create2FactorySalt,
            newConfigPath: _params.upgradeInputPath,
            _outputPath: _params.outputPath,
            governance: _params.governance,
            zkTokenAssetId: _params.zkTokenAssetId,
            testnetVerifier: _params.testnetVerifier
        });
        if (_params.chainRegistrationSender != address(0)) {
            coreAddresses.bridgehub.proxies.chainRegistrationSender = _params.chainRegistrationSender;
        }
        setEcosystemUpgradeExecutor(_params.ecosystemUpgradeExecutor);
        setCoreTransition(_params.coreTransition);
        prepareCTMUpgrade();
        // Declared before the governance calls are written, so the output lists the admin action.
        prepareDefaultCTMAdminCalls();
        prepareDefaultGovernanceCalls();
    }

    function initializeWithArgs(
        address ctmProxy,
        address rollupDAManager,
        bytes32 create2FactorySalt,
        string memory newConfigPath,
        string memory _outputPath,
        address governance,
        bytes32 zkTokenAssetId,
        bool testnetVerifier
    ) public virtual {
        string memory root = vm.projectRoot();
        newConfigPath = string.concat(root, newConfigPath);
        initializeConfigFromArgs({
            ctmProxy: ctmProxy,
            rollupDAManager: rollupDAManager,
            create2FactorySalt: create2FactorySalt,
            newConfigPath: newConfigPath,
            governance: governance,
            zkTokenAssetId: zkTokenAssetId,
            testnetVerifier: testnetVerifier
        });

        console.log("Initialized config from %s", newConfigPath);
        upgradeConfig.outputPath = string.concat(root, _outputPath);
        upgradeConfig.initialized = true;
    }

    function initializeConfig(
        ChainCreationParamsConfig memory chainCreationParams,
        PermanentCTMConfig memory permanentConfig,
        // Optional
        address governance
    ) public {
        require(IChainTypeManager(permanentConfig.ctmProxy).isZKsyncOS(), "CTM is not ZKsync OS");
        // Only override the salt when explicitly provided (non-zero).
        // When zero, the script falls back to the CREATE2_FACTORY_SALT env var or built-in default.
        if (permanentConfig.create2FactorySalt != bytes32(0)) {
            setCreate2Salt(permanentConfig.create2FactorySalt);
        }
        config.l1ChainId = block.chainid;
        newConfig.ctm = permanentConfig.ctmProxy;

        // Must be non-zero: `InteropCenter.initL2` reverts on a zero asset ID. It runs on the genesis path
        // of `performForceDeployedContractsInit` only, so this aborts the genesis of chains created from the
        // release rather than this upgrade — caught here so the misconfiguration surfaces during
        // preparation instead of at a chain's creation.
        require(permanentConfig.zkTokenAssetId != bytes32(0), "zkTokenAssetId must be non-zero");
        config.zkTokenAssetId = permanentConfig.zkTokenAssetId;
        // BEFORE the introspection below, which holds the live protocol version against the target
        // one: reading it there while this assignment still came after left the target at zero, so
        // the check could never fire.
        config.contracts.chainCreationParams = chainCreationParams;

        setAddressesBasedOnCTM();

        address ctmGov = ctmGovernance();
        if (governance != address(0)) {
            config.ownerAddress = governance;
        } else {
            config.ownerAddress = ctmGov;
        }
        config.contracts.governanceSecurityCouncilAddress = Governance(payable(ctmGov)).securityCouncil();
        // config.contracts.governanceMinDelay = Governance(payable(ctmAddresses.admin.governance)).minDelay();
        config.contracts.validatorTimelockExecutionDelay = IValidatorTimelock(
            ctmAddresses.stateTransition.proxies.validatorTimelock
        ).executionDelay();
        config.testnetVerifier = permanentConfig.testnetVerifier;
        config.contracts.maxNumberOfChains = bridgehub.MAX_NUMBER_OF_ZK_CHAINS();
    }

    function initializeConfigFromArgs(
        address ctmProxy,
        address rollupDAManager,
        bytes32 create2FactorySalt,
        string memory newConfigPath,
        address governance,
        bytes32 zkTokenAssetId,
        bool testnetVerifier
    ) internal virtual {
        string memory toml = vm.readFile(newConfigPath);

        // No `era_chain_id` read: the per-env input TOMLs still carry the key for the
        // v31 tooling and the zk-governance PUH redeploy (PUH's real constructor arg),
        // but nothing in this flow consumes an Era chain id.

        PermanentCTMConfig memory permanentConfig = PermanentCTMConfig({
            ctmProxy: ctmProxy,
            create2FactorySalt: create2FactorySalt,
            zkTokenAssetId: zkTokenAssetId,
            testnetVerifier: testnetVerifier
        });
        ChainCreationParamsConfig memory chainCreationParams = getChainCreationParamsConfig(Utils.genesisConfigPath());

        // Optional explicit target protocol version from the upgrade input. The genesis config
        // (`configs/genesis/*/latest.json`) may still declare the PREVIOUS version while an
        // upgrade to the next one is being prepared, so the upgrade-env preset can pin the
        // packed version the emitted `setNewVersionUpgrade` must carry.
        if (toml.keyExists("$.contracts.latest_protocol_version")) {
            chainCreationParams.latestProtocolVersion = toml.readUint("$.contracts.latest_protocol_version");
        }

        initializeConfig(chainCreationParams, permanentConfig, governance);

        if (rollupDAManager != address(0)) {
            ctmAddresses.daAddresses.daContracts.rollupDAManager = rollupDAManager;
        }

        // The CTM domain's live EIP-7702 checker. It is a permanent, argument-less singleton that
        // the `MailboxFacet` pins as an IMMUTABLE, and the live deployment does not expose it
        // (`AddressIntrospector` reports zero), so it is an explicit operator input — the previous
        // prepare recorded it in its output as `[state_transition] eip7702_checker_addr`. Without
        // it every upgrade deploys a fresh checker, which changes the Mailbox's immutable and so
        // drags a Mailbox redeploy — and a facet cut on every chain — behind it. Omit it for a
        // CTM that has none yet and one is deployed. Read AFTER `initializeConfig`, which replaces
        // `ctmAddresses` wholesale from live introspection.
        if (toml.keyExists("$.contracts.eip7702_checker")) {
            setEIP7702Checker(toml.readAddress("$.contracts.eip7702_checker"));
        }
    }

    /// @notice Full default upgrade preparation flow
    function prepareCTMUpgrade() public virtual {
        deployNewCTMContracts();
        console.log("CTM contracts are deployed!");
        prepareL2Side();
        console.log("L2 side prepared!");
        deployStateTransitionDiamondFacets();
        generateUpgradeData();
        console.log("Upgrade data generated!");
        deployUpgradeObjects();
        _requireDeployedImplementationsInstalled();
        saveOutput(upgradeConfig.outputPath);
    }

    /// @notice What this version's prepare SETS OUT to change — a chain-version edge by default,
    ///         or an infrastructure-only one that moves nothing chain-facing. The version
    ///         relationship is held AGAINST this declaration (see {_requireDeclaredKindHolds}),
    ///         never used to derive it: two releases carrying the same version number is a
    ///         consequence of an infrastructure-only edge, not a statement that one is intended,
    ///         and inferring the kind from it would let a mistyped version silently change what is
    ///         being prepared.
    /// @dev A version-script hook rather than a per-environment input key, for the reason
    ///      {changedReleaseMembers} is one: what an upgrade sets out to change is a property of
    ///      the RELEASE, identical on every environment it is prepared for, and reviewed in the
    ///      same diff as the contracts it ships. A TOML key would let the same upgrade be a
    ///      different KIND on two environments, which is the failure this declaration exists to
    ///      remove.
    function upgradeKind() public view virtual returns (UpgradeKind) {
        return UpgradeKind.ChainRelease;
    }

    /// @notice The upgrade objects of the CTM side. A chain-release edge deploys the upgrade
    ///         engine the transition pins, the transition of this edge, and the operation the
    ///         coordinator's `execute` call names; an infrastructure-only edge deploys the operation
    ///         alone; the bootstrap edge deploys its migration and its call sequence instead.
    function deployUpgradeObjects() public virtual {
        _requireDeclaredKindHolds();
        if (upgradeKind() == UpgradeKind.InfrastructureOnly) {
            deployEcosystemUpgradeOperation();
            return;
        }
        upgradeAddresses.upgradeEngine = deployUsedUpgradeContract();
        deployCTMTransition();
        deployEcosystemUpgradeOperation();
    }

    /// @notice Holds this run against the kind it DECLARED (see {upgradeKind}), at the point where
    ///         the declaration decides the shape of the objects and nothing can still move the
    ///         inputs. The version is checked again here — {setAddressesBasedOnCTM} checks the
    ///         INPUT, this checks what the run ended up with — because a version script may set it
    ///         afterwards, and the release pointer because reusing every release member is what
    ///         makes an infrastructure-only edge chain-invisible.
    function _requireDeclaredKindHolds() internal view virtual {
        if (upgradeKind() != UpgradeKind.InfrastructureOnly) {
            return;
        }
        require(
            getNewProtocolVersion() == getOldProtocolVersion(),
            "an infrastructure-only upgrade must not move the protocol version"
        );
        address ctm = ctmAddresses.stateTransition.proxies.chainTypeManager;
        require(
            ctmAddresses.stateTransition.currentRelease == IChainTypeManager(ctm).currentRelease(),
            "an infrastructure-only upgrade must not publish a new release"
        );
    }

    /// @notice Deploys the write-once `CTMTransition` of this upgrade — what governance reviews and
    ///         what the operation names. Everything it pins is a deployment of this run or bound
    ///         live state; nothing is authored calldata.
    /// @dev Rides the CREATE2 factory like every prepare deployment: the Safe bundle replays factory
    ///      transactions only.
    function deployCTMTransition() public virtual {
        address ctm = ctmAddresses.stateTransition.proxies.chainTypeManager;
        address fromRelease = IChainTypeManager(ctm).currentRelease();
        require(fromRelease != address(0), "CTM has no current release: the bootstrap edge must run first");
        address newRelease = ctmAddresses.stateTransition.currentRelease;
        require(newRelease != address(0), "new release not deployed");
        address engine = committedUpgradeEngine();
        upgradeAddresses.ctmTransition = deployTransition(
            TransitionManifest({
                fromRelease: fromRelease,
                newRelease: newRelease,
                upgradeEngine: engine,
                oldProtocolVersionDeadline: UpgradeHelperLib.getOldProtocolDeadline(),
                upgradeTimestamp: 0,
                l2Plan: authoredL2Plan()
            })
        );
    }

    /// @notice Deploys a write-once `CTMTransition` serving `_manifest` and validates it. The one
    ///         derivation every transition a prepare deploys goes through.
    /// @dev From the build ARTIFACT, so a reviewer's own build of the same commit reproduces the
    ///      creation code the object's address is re-derived from.
    /// @param _manifest The edge the transition pins.
    /// @return transition The deployed transition.
    function deployTransition(TransitionManifest memory _manifest) internal returns (address transition) {
        transition = deployViaCreate2AndNotify(
            BytecodeUtils.readBytecodeL1("CTMTransition.sol", "CTMTransition"),
            abi.encode(_manifest),
            "CTMTransition"
        );
        // Fail here, not at execution: every contract the object names must already be deployed,
        // and the object's own revert names the one that is not.
        ICTMTransition(transition).validate();
    }

    /// @notice Deploys the write-once `EcosystemUpgradeOperation` this upgrade's coordinator call
    ///         names: the association of the core prepare's `CoreTransition` with this prepare's
    ///         transition. Nothing is authored — the operation IS that association, and the
    ///         governance call is `execute(operation)`, derivable from its address alone.
    /// @dev Rides the CREATE2 factory like every prepare deployment: the Safe bundle replays
    ///      factory transactions only, so a plain CREATE would leave the `execute` call pointing at
    ///      a codeless address on the real chain.
    function deployEcosystemUpgradeOperation() public virtual {
        require(
            upgradeAddresses.ctmTransition != address(0) || upgradeKind() == UpgradeKind.InfrastructureOnly,
            "transition not deployed"
        );
        ProxyUpgradeRow[] memory inventory = ctmProxyInventory();
        // The object refuses a manifest that changes nothing, but its constructor runs inside the
        // CREATE2 factory, whose failure says only "Failed to deploy contract via create2". Refuse
        // here instead, where the message can name all three legs the version left empty.
        require(
            upgradeAddresses.coreTransition != address(0) ||
                upgradeAddresses.ctmTransition != address(0) ||
                _participatingRows(inventory) != 0,
            "this upgrade changes nothing: no core transition, no infrastructure row and no transition"
        );
        address coordinator = upgradeCoordinator();
        // A call to a codeless address is a silent success, so a coordinator that is not deployed
        // would turn the `execute` call into a no-op the governance bundle reports as executed.
        // Nothing on-chain catches that, which is why it is checked here.
        require(coordinator.code.length != 0, "coordinator has no code");
        // From the build ARTIFACT, for the same reason as the transition above.
        upgradeAddresses.ecosystemUpgradeOperation = deployViaCreate2AndNotify(
            BytecodeUtils.readBytecodeL1("EcosystemUpgradeOperation.sol", "EcosystemUpgradeOperation"),
            abi.encode(
                OperationManifest({
                    coreTransition: upgradeAddresses.coreTransition,
                    // The CTM-domain rows ride the OPERATION, not the transition: replacing an
                    // ecosystem singleton is not a chain-version edge.
                    ctmInfrastructure: inventory,
                    ctmTransition: upgradeAddresses.ctmTransition
                })
            ),
            "EcosystemUpgradeOperation"
        );
    }

    /// @notice The enum-indexed CTM-domain inventory of this edge: a source-checked row for every
    ///         proxy this run deployed a new implementation for, every other slot an explicit inert
    ///         zero. Every row applies through the CTM-domain ProxyAdmin the executor owns.
    function _ctmProxyUpgradeRows() internal view virtual returns (ProxyUpgradeRow[] memory rows) {
        rows = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        rows[uint256(CTMContract.ChainTypeManager)] = _ctmRow(
            ctmAddresses.stateTransition.proxies.chainTypeManager,
            ctmAddresses.stateTransition.implementations.chainTypeManager
        );
        rows[uint256(CTMContract.ValidatorTimelock)] = _ctmRow(
            ctmAddresses.stateTransition.proxies.validatorTimelock,
            ctmAddresses.stateTransition.implementations.validatorTimelock
        );
        rows[uint256(CTMContract.ServerNotifier)] = _ctmRow(
            ctmAddresses.stateTransition.proxies.serverNotifier,
            ctmAddresses.stateTransition.implementations.serverNotifier
        );
    }

    /// @dev The inert (all-zero) row when this run deployed no implementation for the proxy.
    ///      Discovery fills `implementations` from the LIVE EIP-1967 slots, so "a new
    ///      implementation" is the one that DIFFERS from what the proxy already runs (see
    ///      `DefaultCoreUpgrade._row` for the same rule on the ecosystem side).
    function _ctmRow(address _proxy, address _implNew) internal view returns (ProxyUpgradeRow memory row) {
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

    /// @notice CTM-domain slots this version deploys an implementation for and deliberately does
    ///         NOT install. Empty by default — see {_requireDeployedImplementationsInstalled}.
    function uninstalledCTMDeployments() internal view virtual returns (CTMContract[] memory) {
        return new CTMContract[](0);
    }

    /// @notice Refuses an ORPHANED deployment: a CTM-domain implementation this run produced that
    ///         the pinned inventory does not install and the version did not name in
    ///         {uninstalledCTMDeployments}. A deployment nothing references is either a swap that
    ///         silently will not ship or a row builder that was never written, and both look
    ///         exactly like a successful prepare from the output alone.
    function _requireDeployedImplementationsInstalled() internal view virtual {
        ProxyUpgradeRow[] memory rows = ctmProxyInventory();
        address[] memory deployed = _deployedCTMImplementations();
        CTMContract[] memory excused = uninstalledCTMDeployments();
        uint256 length = deployed.length;
        for (uint256 i = 0; i < length; ++i) {
            if (deployed[i] == address(0) || rows[i].implNew == deployed[i]) {
                continue;
            }
            bool accountedFor = false;
            for (uint256 j = 0; j < excused.length; ++j) {
                if (uint256(excused[j]) == i) {
                    accountedFor = true;
                    break;
                }
            }
            require(
                accountedFor,
                // solhint-disable-next-line func-named-parameters
                string.concat(
                    "orphaned CTM-domain deployment at inventory slot ",
                    vm.toString(i),
                    " (",
                    vm.toString(deployed[i]),
                    "): this run deployed it but the pinned inventory does not install it. Either add its row to "
                    "`_ctmProxyUpgradeRows()`, or name the slot in `uninstalledCTMDeployments()`."
                )
            );
        }
    }

    /// @dev The implementations THIS RUN produced, over the same slot space as
    ///      {_ctmProxyUpgradeRows} so the orphan check compares like with like (see
    ///      `DefaultCoreUpgrade._deployedCoreImplementations` for the ecosystem counterpart).
    function _deployedCTMImplementations() private view returns (address[] memory impls) {
        impls = new address[](CTM_CONTRACT_COUNT);
        StateTransitionContracts memory proxies = ctmAddresses.stateTransition.proxies;
        StateTransitionContracts memory implementations = ctmAddresses.stateTransition.implementations;
        impls[uint256(CTMContract.ChainTypeManager)] = _deployedCTMImpl(
            proxies.chainTypeManager,
            implementations.chainTypeManager
        );
        impls[uint256(CTMContract.ValidatorTimelock)] = _deployedCTMImpl(
            proxies.validatorTimelock,
            implementations.validatorTimelock
        );
        impls[uint256(CTMContract.ServerNotifier)] = _deployedCTMImpl(
            proxies.serverNotifier,
            implementations.serverNotifier
        );
        impls[uint256(CTMContract.BytecodesSupplier)] = _deployedCTMImpl(
            proxies.bytecodesSupplier,
            implementations.bytecodesSupplier
        );
        impls[uint256(CTMContract.PermissionlessValidator)] = _deployedCTMImpl(
            proxies.permissionlessValidator,
            implementations.permissionlessValidator
        );
    }

    /// @dev `_impl` when it is a REPLACEMENT this run produced, zero otherwise — see
    ///      `DefaultCoreUpgrade._deployedImpl`.
    function _deployedCTMImpl(address _proxy, address _impl) private view returns (address) {
        if (_impl == address(0) || _proxy == address(0)) {
            return address(0);
        }
        return _impl == Utils.getImplementation(_proxy) ? address(0) : _impl;
    }

    /// @dev How many slots of an enum-indexed inventory actually participate.
    function _participatingRows(ProxyUpgradeRow[] memory _inventory) internal pure returns (uint256 count) {
        uint256 length = _inventory.length;
        for (uint256 i = 0; i < length; ++i) {
            if (_inventory[i].implNew != address(0)) {
                ++count;
            }
        }
    }

    /// @notice The L2 side this version authors (see {AuthoredL2Side}). The default is an L1-only
    ///         edge — no delegate, no extra bytecode, no composer, nothing to publish. A version
    ///         whose L2 built-ins change derives their rows from the release pair on-chain and MUST
    ///         author the delegate that initializes them and list every bytecode the resulting plan
    ///         needs published (the v35 bootstrap shows the shape).
    function authorL2Side() internal virtual returns (AuthoredL2Side memory side) {
        // The zero value is the L1-only side: an empty plan and nothing to publish.
        return side;
    }

    /// @notice The authored L2 plan of this edge, factory dependencies published and pinned — what
    ///         the upgrade object of this run carries as its `l2Plan`.
    function authoredL2Plan() internal view returns (AuthoredL2Plan memory) {
        require(upgradeConfig.l2SidePrepared, "L2 side not prepared");
        return abi.decode(encodedAuthoredL2Plan, (AuthoredL2Plan));
    }

    /// @notice The `RegistryBootstrapMigration` this run deploys, or zero for every edge that is
    ///         not a bootstrap.
    /// @dev Exists so `saveOutput` can NAME the migration: the bootstrap bundle targets it, but it
    ///      is not reachable from any other reported address, and a reviewer should not have to
    ///      decode bundle calldata to find the object the edge runs.
    /// @notice The upgrade engine this edge commits: this prepare's own deployment until the
    ///         object that pins it exists, and that object's pin from then on. Reading it back off
    ///         the object means the output cannot name an engine the committed edge does not pin.
    function committedUpgradeEngine() public view virtual returns (address) {
        address transition = upgradeAddresses.ctmTransition;
        if (transition != address(0)) {
            return ICTMTransition(transition).upgradeEngine();
        }
        if (upgradeKind() == UpgradeKind.InfrastructureOnly) {
            // No chain crosses an infrastructure-only edge, so there is no engine to commit and
            // the output must not name one.
            return address(0);
        }
        require(upgradeAddresses.upgradeEngine != address(0), "upgrade engine not deployed");
        return upgradeAddresses.upgradeEngine;
    }

    function bootstrapMigrationAddress() public view virtual returns (address) {
        return address(0);
    }

    /// @notice The CTM-domain inventory of this edge, indexed by `CTMContract` — ONE definition,
    ///         which both the admin calls this prepare emits and the compose step's operation are
    ///         rendered from.
    /// @dev The bootstrap edge reads it back off its own pinned object; a recurring edge cannot,
    ///      because the object that pins the rows (the `EcosystemUpgradeOperation`) is deployed by
    ///      the compose step AFTER this prepare — the prepare's `[registry].ctm_infrastructure`
    ///      output is that step's input.
    function ctmProxyInventory() internal view virtual returns (ProxyUpgradeRow[] memory) {
        address migration = bootstrapMigrationAddress();
        if (migration != address(0)) {
            return RegistryBootstrapMigration(migration).getManifest().ctmProxyUpgrades;
        }
        require(
            upgradeAddresses.ctmTransition != address(0) || upgradeKind() == UpgradeKind.InfrastructureOnly,
            "no upgrade object deployed: the CTM-domain rows are read from it"
        );
        return _ctmProxyUpgradeRows();
    }

    /// @notice The CTM domain's bound `CTMUpgradeExecutor`: the CTM's owner once the bootstrap edge
    ///         has handed the domain over. The operation naming this transition is applied through
    ///         it.
    function boundCTMUpgradeExecutor() public view virtual returns (address) {
        address ctm = ctmAddresses.stateTransition.proxies.chainTypeManager;
        address executor = IOwnable(ctm).owner();
        require(executor.code.length != 0, "CTM owner is not a contract: run the bootstrap edge first");
        require(
            address(CTMUpgradeExecutor(payable(executor)).CHAIN_TYPE_MANAGER()) == ctm,
            "CTM owner is not an executor bound to it"
        );
        return executor;
    }

    /// @notice The ecosystem's lifecycle coordinator (`EcosystemUpgradeExecutor`): the one the
    ///         CTM's bound executor answers to. The bootstrap edge, which binds it, overrides this
    ///         with the core prepare's output.
    function upgradeCoordinator() public view virtual returns (address) {
        address coordinator = CTMUpgradeExecutor(payable(boundCTMUpgradeExecutor())).coordinator();
        require(coordinator != address(0), "the bound CTM executor answers to no coordinator");
        return coordinator;
    }

    /// @notice The CTM domain's live EIP-7702 checker (see `CTMUpgradeParams.eip7702Checker`).
    ///         Zero leaves it to be deployed fresh.
    function setEIP7702Checker(address _eip7702Checker) public virtual {
        ctmAddresses.admin.eip7702Checker = _eip7702Checker;
    }

    /// @notice The release members this version SETS OUT to change. Everything else must come
    ///         through unchanged, and the prepare refuses to replace anything not named here — so
    ///         "change one contract" cannot quietly become "replace the facet set" because the
    ///         local build differs from the one that produced the live code.
    /// @dev Names are the `deploySimpleContract` names of the members that pass through
    ///      {DeployCTMUtils._deployReleaseMember}: the six facets, `DiamondInit`, `L1GenesisUpgrade`
    ///      and `EIP7702Checker`. The verifier is not among them — a version that replaces it does so
    ///      by overriding the deploy step, which IS the declaration. The default is EMPTY: a
    ///      recurring upgrade that changes nothing about the release reuses all of it, and the
    ///      release object itself.
    function changedReleaseMembers() internal view virtual returns (string[] memory) {
        return new string[](0);
    }

    /// @notice Refuses a replacement this version did not declare (see {changedReleaseMembers}).
    function _requireDeclaredReleaseMemberChange(string memory _name, address _live) internal virtual override {
        string[] memory declared = changedReleaseMembers();
        uint256 length = declared.length;
        for (uint256 i = 0; i < length; ++i) {
            if (compareStrings(declared[i], _name)) {
                return;
            }
        }
        console.log("Undeclared release member change:", _name);
        console.log("  live:", _live);
        console.logBytes32(_live.codehash);
        // The two causes are indistinguishable from here, so the message names both.
        require(
            false,
            string.concat(
                "release member '",
                _name,
                "' would be replaced but this version does not declare it as changed. Either add it to "
                "`changedReleaseMembers()`, or the local build differs from the one that produced the live "
                "code (for the Mailbox, a missing `[contracts] eip7702_checker` input is the usual cause)."
            )
        );
    }

    /// @notice A live release member may serve this release when it ALREADY runs the code the
    ///         current sources produce with this run's constructor arguments — so an upgrade
    ///         deploys only the members it changes, and one that changes none of them reuses the
    ///         release object itself.
    /// @dev The identity check needs a local deployment: an artifact's `deployedBytecode` carries
    ///      ZEROED immutable slots, so it cannot be compared against live code. The probe is a
    ///      plain CREATE in the script's own EVM and is never broadcast — nothing reaches the
    ///      chain — and it is exact, immutables included (the same technique
    ///      `GatewayCTMDeployerHelper` uses to predict Gateway codehashes).
    function _canReuseReleaseMember(string memory _name, address _live) internal virtual override returns (bool) {
        if (_live == address(0) || _live.code.length == 0) {
            return false;
        }
        if (address(releaseMemberProbe) == address(0)) {
            // Plain CREATE, never broadcast: it lives only inside this run's simulation.
            releaseMemberProbe = new ReleaseMemberProbe();
        }
        return _live.codehash == releaseMemberProbe.codehashOf(_name, getCreationCalldata(_name));
    }

    /// @notice Declares one governance/admin call this prepare emits that the upgrade objects do
    ///         not describe (see {ExternalActionsLib}).
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

    /// @notice The per-chain upgrade engine the transition pins: it composes each chain's L2 leg
    ///         from the transition's plan and leaves an L1-only edge's all-zero L2 transaction alone.
    function deployUsedUpgradeContract() internal virtual returns (address) {
        return deploySimpleContract("DefaultUpgrade");
    }

    /// @notice Deploy what the release deploy (`deployStateTransitionDiamondFacets`) needs first —
    ///         the EIP-7702 checker the fresh MailboxFacet takes, and the force-deployments blob the
    ///         release pins.
    function deployNewCTMContracts() public virtual {
        deployEIP7702Checker();
        generateFixedForceDeploymentsData();
    }

    /// @notice The CTM domain's governance. Once the bootstrap edge has handed the domain to the
    ///         bound executor, the CTM's owner IS that executor and governance is its owner; the
    ///         bootstrap prepare (which runs before that handover) overrides this with the CTM's
    ///         owner itself.
    function ctmGovernance() internal view virtual returns (address) {
        return IOwnable(boundCTMUpgradeExecutor()).owner();
    }

    /// @notice The step between the release deploy and the upgrade objects. Nothing on the default
    ///         path: it is where a version script hangs a deployment that needs the release to
    ///         already exist (the bootstrap edge's engine pins it as an immutable).
    /// @dev The chain-CREATION cut is deliberately not recomputed here: from v35 the CTM builds it
    ///      per chain creation from its pinned release, so an upgrade prepare has nothing to say
    ///      about it (see the retired `diamond_cut_data` output field).
    function generateUpgradeData() public virtual {
        require(upgradeConfig.initialized, "Not initialized");
        // TODO Return the require after getting the version from bridgehub
        //        require(upgradeConfig.ecosystemContractsDeployed, "Ecosystem contracts not deployed");
    }

    function getOwnerAddress() public virtual returns (address) {
        return config.ownerAddress;
    }

    /// @notice The coordinator the core prepare of the bootstrap edge deployed (see
    ///         {upgradeCoordinator}). Set from the prepare params in production; in-forge harnesses
    ///         that drive both prepares call it directly.
    function setEcosystemUpgradeExecutor(address _ecosystemUpgradeExecutor) public virtual {
        upgradeAddresses.ecosystemUpgradeExecutor = _ecosystemUpgradeExecutor;
    }

    function setCoreTransition(address _coreTransition) public virtual {
        upgradeAddresses.coreTransition = _coreTransition;
    }

    function setNewProtocolVersion(uint256 _protocolVersion) public virtual {
        config.contracts.chainCreationParams.latestProtocolVersion = _protocolVersion;
    }

    function getNewProtocolVersion() public view virtual returns (uint256) {
        return config.contracts.chainCreationParams.latestProtocolVersion;
    }

    function getOldProtocolVersion() public view virtual returns (uint256) {
        return newConfig.oldProtocolVersion;
    }

    function getBridgehubAdmin() public virtual returns (address admin) {
        return coreAddresses.shared.bridgehubAdmin;
    }

    function setAddressesBasedOnCTM() internal virtual {
        address ctm = newConfig.ctm;

        // Verify CTM contract exists
        require(ctm.code.length > 0, "CTM contract does not exist at specified address");

        address bridgehubAddr = ChainTypeManager(ctm).BRIDGE_HUB();
        bridgehub = L1Bridgehub(bridgehubAddr);

        ctmAddresses = AddressIntrospector.getCTMAddresses(ChainTypeManager(ctm));
        coreAddresses = AddressIntrospector.getCoreDeployedAddresses(bridgehubAddr);

        config.ownerAddress = ctmAddresses.admin.governance;

        address representativeChain = AddressIntrospector.getRepresentativeZkChain(bridgehubAddr);
        if (representativeChain != address(0)) {
            discoveredRepresentativeZkChain = AddressIntrospector.getZkChainAddresses(IZKChain(representativeChain));
            ctmAddresses.daAddresses.daContracts.rollupSLDAValidator = discoveredRepresentativeZkChain.l1DAValidator;
        } else {
            // Chainless ecosystem (fresh deployment), use up-to-date addresses
            console.log("No registered chain in bridgehub, using up-to-date addresses");
        }

        // A pre-registry CTM has no release to read its members from, so discovery read them off a
        // chain at the CTM's version — which must therefore exist. A registry-era CTM's members
        // come from its release, whatever version its chains are at.
        if (ctmAddresses.stateTransition.currentRelease == address(0)) {
            upToDateZkChain = AddressIntrospector.getUptoDateZkChainAddresses(ChainTypeManager(ctm));
        }

        uint256 ctmProtocolVersion = IChainTypeManager(ctm).protocolVersion();
        newConfig.oldProtocolVersion = ctmProtocolVersion;
        if (upgradeKind() == UpgradeKind.TransitionReplacement) {
            // The edge's versions are the replaced transition's, not the input's.
            return;
        }
        if (upgradeKind() == UpgradeKind.InfrastructureOnly) {
            // The declaration decides the kind; the configured version is held against it. An
            // input naming a version the CTM is not already on describes a chain-version edge,
            // which is not what this version script prepares — and the two disagreeing is exactly
            // the misconfiguration the declaration exists to surface rather than silently obey.
            require(
                ctmProtocolVersion == getNewProtocolVersion(),
                string.concat(
                    "an infrastructure-only upgrade must not move the protocol version: the input names ",
                    vm.toString(getNewProtocolVersion()),
                    " and the ChainTypeManager runs ",
                    vm.toString(ctmProtocolVersion)
                )
            );
            return;
        }
        require(
            ctmProtocolVersion != getNewProtocolVersion(),
            "The new protocol version is already present on the ChainTypeManager"
        );
    }

    /// @notice Builds the force-deployments blob the release pins and stores it for
    ///         {deployCurrentRelease}, which refuses to pin an empty one.
    function generateFixedForceDeploymentsData() internal {
        require(config.ownerAddress != address(0), "owner not set");

        generatedData.forceDeploymentsData = abi.encode(_buildForceDeploymentsData(config.ownerAddress));
    }

    /////////////////////////// Blockchain interactions ////////////////////////////

    /// @notice Fixes the L2 side of this edge: takes the version's authored side and publishes
    ///         exactly the bytecodes it lists on the CTM's `BytecodesSupplier`. An L1-only edge
    ///         publishes nothing.
    function prepareL2Side() public virtual {
        AuthoredL2Side memory side = authorL2Side();
        if (side.factoryDependencies.length != 0) {
            BytecodesSupplier supplier = BytecodesSupplier(ctmAddresses.stateTransition.proxies.bytecodesSupplier);
            BytecodePublisher.publishAndProcessFactoryDeps(
                supplier,
                SystemContractsProcessing.deduplicateBytecodes(side.factoryDependencies)
            );
        }
        encodedAuthoredL2Plan = abi.encode(side.plan);
        upgradeConfig.l2SidePrepared = true;
    }

    ////////////////////////////// Preparing calls /////////////////////////////////

    /// @notice Writes this prepare's `[governance_calls] calls`: whatever a version script declared
    ///         as a governance external action (the bootstrap edge declares its whole bundle). The
    ///         executor call itself is not among them — the merge derives it from the operation.
    function prepareDefaultGovernanceCalls() public virtual returns (Call[] memory calls) {
        calls = prepareGovernanceCalls();
        string memory governanceCallsSerialized = vm.serializeBytes("governance_calls", "calls", abi.encode(calls));

        // Upstream forge's keyed `vm.writeToml(json, path, key)` silently no-ops when the key
        // does not exist in the file yet, so append sections by re-serializing into the same
        // "root" object and rewriting the whole file instead.
        vm.serializeString("root", "external_actions", externalActionEntries());
        string memory updatedToml = vm.serializeString("root", "governance_calls", governanceCallsSerialized);
        vm.writeToml(updatedToml, upgradeConfig.outputPath);
    }

    /// @notice The CTM-ADMIN calls of this prepare — calls on authority governance does not hold —
    ///         written to `[ctm_admin_calls]` and declared as `admin`-phase external actions. Only
    ///         the registry bootstrap has any: the ChainAdmin's half of the one-time ServerNotifier
    ///         handover ({serverNotifierHandoverCalls}). The section is written either way so
    ///         tooling reads one shape.
    function prepareDefaultCTMAdminCalls() public virtual returns (Call[] memory calls) {
        calls = serverNotifierHandoverCalls();
        address chainAdmin;
        address chainAdminOwner;
        uint256 length = calls.length;
        if (length != 0) {
            // The administrator the section records: the live owner of the first call's target.
            chainAdmin = IOwnable(calls[0].target).owner();
            chainAdminOwner = chainAdmin.code.length == 0 ? address(0) : IOwnable(chainAdmin).owner();
        }
        for (uint256 i = 0; i < length; ++i) {
            declareExternalAction(
                ExternalActionsLib.PHASE_ADMIN,
                "ServerNotifier handover to the CTM domain (ctm_admin_calls)",
                "the live owner of the call target (normally the ChainAdmin)",
                calls[i]
            );
        }
        vm.serializeAddress("ctm_admin_calls", "chain_admin", chainAdmin);
        vm.serializeAddress("ctm_admin_calls", "chain_admin_owner", chainAdminOwner);

        string memory ctmAdminCallsSerialized = vm.serializeBytes(
            "ctm_admin_calls",
            "server_notifier_handover",
            abi.encode(calls)
        );

        // See the note in prepareDefaultGovernanceCalls on why keyed writeToml is not used here.
        string memory updatedCtmAdminToml = vm.serializeString("root", "ctm_admin_calls", ctmAdminCallsSerialized);
        vm.writeToml(updatedCtmAdminToml, upgradeConfig.outputPath);
    }

    /// @notice The ChainAdmin's half of the one-time ServerNotifier handover (see
    ///         {docs/upgrade-operations.md}). Empty by default: once the registry bootstrap
    ///         has run, the notifier is administered and owned like the rest of the CTM domain.
    function serverNotifierHandoverCalls() public view virtual returns (Call[] memory calls) {
        return calls;
    }

    /// @notice The governance bundle of this prepare: only what a version script declared as a
    ///         governance external action. The executor call itself —
    ///         `EcosystemUpgradeExecutor.execute(operation)` — is authored nowhere: it is a function
    ///         of the operation's address, and the merge derives it from it.
    function prepareGovernanceCalls() public virtual returns (Call[] memory calls) {
        return externalActions.callsForPhase(ExternalActionsLib.PHASE_GOVERNANCE);
    }

    function getAddresses() public view override returns (CTMDeployedAddresses memory) {
        return ctmAddresses;
    }

    function saveOutput(string memory outputPath) internal virtual override {
        // Serialize newly deployed state transition addresses
        vm.serializeAddress(
            "state_transition",
            "chain_type_manager_implementation_addr",
            ctmAddresses.stateTransition.implementations.chainTypeManager
        );
        vm.serializeAddress(
            "state_transition",
            "chain_type_manager_proxy",
            ctmAddresses.stateTransition.proxies.chainTypeManager
        );
        vm.serializeAddress("state_transition", "verifier_addr", ctmAddresses.stateTransition.verifiers.verifier);
        vm.serializeAddress("state_transition", "admin_facet_addr", ctmAddresses.stateTransition.facets.adminFacet);
        vm.serializeAddress("state_transition", "mailbox_facet_addr", ctmAddresses.stateTransition.facets.mailboxFacet);
        vm.serializeAddress(
            "state_transition",
            "executor_facet_addr",
            ctmAddresses.stateTransition.facets.executorFacet
        );
        vm.serializeAddress("state_transition", "getters_facet_addr", ctmAddresses.stateTransition.facets.gettersFacet);
        vm.serializeAddress(
            "state_transition",
            "migrator_facet_addr",
            ctmAddresses.stateTransition.facets.migratorFacet
        );
        vm.serializeAddress(
            "state_transition",
            "committer_facet_addr",
            ctmAddresses.stateTransition.facets.committerFacet
        );
        vm.serializeAddress("state_transition", "diamond_init_addr", ctmAddresses.stateTransition.facets.diamondInit);
        vm.serializeAddress("state_transition", "genesis_upgrade_addr", ctmAddresses.stateTransition.genesisUpgrade);
        vm.serializeAddress(
            "state_transition",
            "verifier_fflonk_addr",
            ctmAddresses.stateTransition.verifiers.verifierFflonk
        );
        vm.serializeAddress(
            "state_transition",
            "verifier_plonk_addr",
            ctmAddresses.stateTransition.verifiers.verifierPlonk
        );
        vm.serializeAddress(
            "state_transition",
            "validator_timelock_implementation_addr",
            ctmAddresses.stateTransition.implementations.validatorTimelock
        );
        vm.serializeAddress(
            "state_transition",
            "validator_timelock_addr",
            ctmAddresses.stateTransition.proxies.validatorTimelock
        );
        vm.serializeAddress(
            "state_transition",
            "bytecodes_supplier_addr",
            ctmAddresses.stateTransition.proxies.bytecodesSupplier
        );
        vm.serializeAddress("state_transition", "eip7702_checker_addr", ctmAddresses.admin.eip7702Checker);
        vm.serializeAddress(
            "state_transition",
            "permissionless_validator_addr",
            ctmAddresses.stateTransition.proxies.permissionlessValidator
        );
        if (ctmAddresses.stateTransition.implementations.serverNotifier != address(0)) {
            vm.serializeAddress(
                "state_transition",
                "server_notifier_implementation_addr",
                ctmAddresses.stateTransition.implementations.serverNotifier
            );
        }
        string memory stateTransition = vm.serializeAddress(
            "state_transition",
            "default_upgrade_addr",
            committedUpgradeEngine()
        );

        // Serialize newly deployed upgrade addresses
        vm.serializeAddress("deployed_addresses", "chain_admin", discoveredRepresentativeZkChain.chainAdmin);
        vm.serializeAddress("deployed_addresses", "access_control_restriction_addr", address(0));
        vm.serializeAddress("deployed_addresses", "transparent_proxy_admin", ctmAddresses.admin.transparentProxyAdmin);
        vm.serializeAddress(
            "deployed_addresses",
            "rollup_l1_da_validator_addr",
            discoveredRepresentativeZkChain.l1DAValidator
        );
        vm.serializeAddress("deployed_addresses", "validium_l1_da_validator_addr", address(0));
        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "l1_rollup_da_manager",
            ctmAddresses.daAddresses.daContracts.rollupDAManager
        );

        // Serialize generated upgrade data. There is no `diamond_cut_data`: the chain-creation cut
        // is the CTM's own function of its pinned release, not a prepare output.
        vm.serializeBytes("contracts_newConfig", "force_deployments_data", generatedData.forceDeploymentsData);

        // Serialize protocol version info (needed for upgrade)
        vm.serializeUint("contracts_newConfig", "new_protocol_version", getNewProtocolVersion());
        vm.serializeBool("contracts_newConfig", "is_testnet", config.testnetVerifier);
        string memory contractsConfig = vm.serializeUint(
            "contracts_newConfig",
            "old_protocol_version",
            newConfig.oldProtocolVersion
        );

        // Serialize root structure
        vm.serializeString("root", "deployed_addresses", deployedAddresses);
        vm.serializeString("root", "state_transition", stateTransition);
        vm.serializeString("root", "contracts_config", contractsConfig);
        // The upgrade objects of this run — what governance reviews and the operation names.
        vm.serializeAddress("registry", "ctm_transition_addr", upgradeAddresses.ctmTransition);
        vm.serializeAddress("registry", "ctm_release_addr", ctmAddresses.stateTransition.currentRelease);
        // The CTM-domain rows of this edge, as the operation this prepare deployed pins them. A
        // bootstrap edge deploys no operation — its own object already carries them.
        vm.serializeBytes(
            "registry",
            "ctm_infrastructure",
            upgradeAddresses.ecosystemUpgradeOperation != address(0) ? abi.encode(_ctmProxyUpgradeRows()) : bytes("")
        );
        address bootstrapMigrationAddr = bootstrapMigrationAddress();
        vm.serializeAddress("registry", "bootstrap_migration_addr", bootstrapMigrationAddr);
        // The bound executor is named whenever it is known: after a bootstrap prepare deployed
        // it, or once the CTM's live owner is one. Tooling reads it, with the
        // transition, as this CTM's leg of the operation; a bootstrap edge has no transition, so
        // nothing composes over it.
        bool executorKnown = upgradeAddresses.ctmTransition != address(0) || bootstrapMigrationAddr != address(0);
        vm.serializeAddress(
            "registry",
            "ctm_upgrade_executor_addr",
            executorKnown ? boundCTMUpgradeExecutor() : address(0)
        );
        // The operation and the coordinator it is driven through: the merge derives this upgrade's
        // governance call — `execute(operation)` — from exactly these two addresses.
        vm.serializeAddress("registry", "coordinator_addr", upgradeCoordinator());
        string memory registry = vm.serializeAddress(
            "registry",
            "operation_addr",
            upgradeAddresses.ecosystemUpgradeOperation
        );
        vm.serializeString("root", "registry", registry);
        (bool recorded, string memory executorsRecord) = upgradeExecutorsRecord();
        if (recorded) {
            vm.serializeString("root", "upgrade_executors", executorsRecord);
        }
        // The salt this run's CREATE2 deployments used, so a reviewer re-derives its objects
        // without being told it out of band.
        vm.serializeBytes32("root", "create2_factory_salt", _create2FactorySalt);
        string memory toml = vm.serializeBytes("root", "chain_upgrade_diamond_cut", getChainUpgradeDiamondCutData());

        vm.writeToml(toml, outputPath);
    }

    /// @notice The `[upgrade_executors]` record of the executor THIS run deployed (see
    ///         {UpgradeExecutorsRecord}). A recurring prepare deploys none and records nothing.
    /// @return recorded Whether this run deployed one.
    /// @return json The serialized record.
    function upgradeExecutorsRecord() internal virtual returns (bool recorded, string memory json) {}

    function getCTMAddress() public view returns (address) {
        return newConfig.ctm;
    }

    /// @notice Reads the upgrade cut from the pinned transition. Empty on an infrastructure-only
    ///         edge: no chain crosses it, so there is no cut for one to take.
    function getChainUpgradeDiamondCutData() public view virtual returns (bytes memory) {
        if (upgradeAddresses.ctmTransition == address(0) && upgradeKind() == UpgradeKind.InfrastructureOnly) {
            return bytes("");
        }
        require(upgradeAddresses.ctmTransition != address(0), "transition not deployed");
        return abi.encode(CTMUpgradeComposer.buildUpgradeCutData(ICTMTransition(upgradeAddresses.ctmTransition)));
    }

    ////////////////////////////// Misc utils /////////////////////////////////

    // add this to be excluded from coverage report
    function test() internal override {}
}
