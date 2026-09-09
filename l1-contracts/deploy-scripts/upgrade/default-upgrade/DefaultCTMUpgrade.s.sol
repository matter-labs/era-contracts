// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// TODO(EVM-1644): LEGACY UPGRADE PROCESS — remove once the registry-driven upgrade process
// (contracts/upgrades/registry: CTMUpgradeExecutor / EcosystemUpgradeExecutor +
// release/transition registries) has fully replaced off-chain governance-calldata generation. Kept for the
// v34 bootstrap edge, which still ships stage0/1/2 calls (the committed cut itself is already
// facet-less; only the call orchestration remains script-composed).

// solhint-disable no-console, gas-custom-errors

import {Script, console2 as console} from "forge-std/Script.sol";

import {stdToml} from "forge-std/StdToml.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {SafeCast} from "@openzeppelin/contracts-v4/utils/math/SafeCast.sol";

import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Utils} from "../../utils/Utils.sol";
import {ChainCreationParamsConfig, ZkChainAddresses} from "../../utils/Types.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManagerBase} from "contracts/state-transition/ChainTypeManagerBase.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IL2ContractDeployer} from "contracts/common/interfaces/IL2ContractDeployer.sol";

import {Governance} from "contracts/governance/Governance.sol";

import {Call} from "contracts/governance/Common.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";

import {CTMDeployedAddresses} from "../../ctm/DeployCTMUtils.s.sol";

import {BytecodePublisher, PublishFactoryDepsResult} from "../../utils/bytecode/BytecodePublisher.s.sol";
import {L2ContractHelper} from "contracts/common/l2-helpers/L2ContractHelper.sol";
import {L2EcosystemContract} from "../../ecosystem/CoreContract.sol";
import {CoreOnGatewayHelper} from "../../ecosystem/CoreOnGatewayHelper.sol";
import {BytecodesSupplier} from "contracts/upgrades/BytecodesSupplier.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {FixedForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IValidatorTimelock} from "contracts/state-transition/validators/interfaces/IValidatorTimelock.sol";

import {AddressIntrospector} from "../../utils/AddressIntrospector.sol";
import {CTMUpgradeBase} from "./CTMUpgradeBase.sol";
import {BytecodeUtils} from "../../utils/bytecode/BytecodeUtils.s.sol";
import {ReleaseMemberProbe} from "./ReleaseMemberProbe.sol";
import {UpgradeHelperLib} from "./UpgradeHelperLib.sol";
import {CTMUpgradeParams} from "./UpgradeParams.sol";
import {UpgradeUtils} from "./UpgradeUtils.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {UpgradeChainCall} from "deploy-scripts/utils/UpgradeChainCall.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol";
import {
    AuthoredL2Plan,
    PinnedContract,
    ProxyUpgradeRow,
    TransitionManifest
} from "contracts/upgrades/registry/RegistryTypes.sol";
import {CTM_CONTRACT_COUNT, CTMContract} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ExternalActionsLib} from "./ExternalActionsLib.sol";

/// @notice The CTM side of a registry-driven upgrade prepare, run after the core prepare: deploys
///         the new release (facets, DiamondInit, verifier, upgrade engine) and pins the edge in a
///         write-once `CTMTransition` — naming the core prepare's `CoreRegistry` as its ecosystem
///         leg and a fresh `GovernanceUpgradeTimer` bound to the CTM executor. The governance
///         stages it emits are exactly `CTMUpgradeExecutor.stage0/1/2(transition)`; anything a
///         version script still needs governance (or an admin) to do is declared as an external
///         action and listed in the output.
/// @dev Version scripts inherit and override; the v34 bootstrap edge deploys no transition and
///      declares every call of its one-time edge instead.
contract DefaultCTMUpgrade is Script, CTMUpgradeBase {
    using stdToml for string;
    using ExternalActionsLib for ExternalActionsLib.Ledger;

    uint256 internal constant ZKSYNC_OS_TEST_CREATE_CHAIN_ID = 556;

    /// @dev Deployed on first use; see {ReleaseMemberProbe} for why it is a separate contract.
    ReleaseMemberProbe internal releaseMemberProbe;

    // solhint-disable-next-line gas-struct-packing
    struct UpgradeDeployedAddresses {
        address upgradeTimer;
        /// @dev Bootstrap-only: the recurring stages check pause state on-chain.
        address upgradeStageValidator;
        address ecosystemUpgradeExecutor;
        /// @dev The core prepare's `CoreRegistry` (an input, see `CTMUpgradeParams`); zero when the
        ///      upgrade has no ecosystem leg.
        address coreRegistry;
        /// @dev The write-once transition this prepare deploys (zero for the bootstrap edge).
        address ctmTransition;
    }

    // solhint-disable-next-line gas-struct-packing
    struct AdditionalConfig {
        address ctm;
        uint256 oldProtocolVersion;
        address ecosystemAdminAddress;
        uint256 governanceUpgradeTimerInitialDelay;
        bool hasPreV32IntrospectionOverride;
        bool usePreV32IntrospectionOverride;
    }

    // solhint-disable-next-line gas-struct-packing
    struct NewlyGeneratedData {
        /// @dev The committed upgrade cut, READ from the upgrade object that composes it on-chain.
        bytes upgradeCutData;
    }

    /// @notice Internal state of the upgrade script
    struct EcosystemUpgradeConfig {
        bool initialized;
        bool fixedForceDeploymentsDataGenerated;
        bool upgradeCutPrepared;
        bool factoryDepsPublished;
        // TODO set it based on version of the BRIDGEHUB before upgrade

        bool ecosystemContractsDeployed;
        string outputPath;
    }

    struct PermanentCTMConfig {
        bytes32 create2FactorySalt;
        address ctmProxy;
        address bytecodesSupplier;
        /// @dev ZK token asset ID, used by `InteropCenter.initL2` for fixed-fee bundles.
        ///      MUST be non-zero — `InteropCenter.initL2` reverts otherwise, which would abort the
        ///      L2 upgrade transaction.
        bytes32 zkTokenAssetId;
    }

    // The output of the script
    NewlyGeneratedData internal newlyGeneratedData;
    UpgradeDeployedAddresses internal upgradeAddresses;
    EcosystemUpgradeConfig internal upgradeConfig;

    // Input for the script
    AdditionalConfig internal newConfig;

    // Discovered addresses
    ZkChainAddresses internal discoveredRepresentativeZkChain;
    ZkChainAddresses internal upToDateZkChain;
    L1Bridgehub internal bridgehub;

    PublishFactoryDepsResult internal factoryDepsResult;

    /// @dev The governance/admin calls this prepare emits that the upgrade objects do not
    ///      describe (see {ExternalActionsLib}).
    ExternalActionsLib.Ledger internal externalActions;

    /// @notice Single-call entry point invoked by the protocol-ops CLI's `upgrade-prepare-all`,
    ///         once per CTM proxy (`ICTMUpgradeV31` in `contracts/script-interfaces/IUpgradeV31.sol`).
    function noGovernancePrepare(CTMUpgradeParams memory _params) public virtual {
        // solhint-disable-next-line func-named-parameters
        initializeWithArgs(
            _params.ctmProxy,
            _params.bytecodesSupplier,
            _params.rollupDAManager,
            _params.create2FactorySalt,
            _params.upgradeInputPath,
            _params.outputPath,
            _params.governance,
            _params.zkTokenAssetId
        );
        if (_params.chainRegistrationSender != address(0)) {
            coreAddresses.bridgehub.proxies.chainRegistrationSender = _params.chainRegistrationSender;
        }
        setEcosystemUpgradeExecutor(_params.ecosystemUpgradeExecutor);
        setCoreRegistry(_params.coreRegistry);
        prepareCTMUpgrade();
        // Declared before the governance calls are written, so the output lists the admin action.
        prepareDefaultCTMAdminCalls();
        prepareDefaultGovernanceCalls();

        // Test-only calls (`test_create_chain`, `test_upgrade_chain`) ride the CTM output TOML
        // so protocol-ops can lift them into the merged `ecosystem.toml` for simulator checks.
        prepareDefaultTestUpgradeCalls();
    }

    function initializeWithArgs(
        address ctmProxy,
        address bytecodesSupplier,
        address rollupDAManager,
        bytes32 create2FactorySalt,
        string memory newConfigPath,
        string memory _outputPath,
        address governance,
        bytes32 zkTokenAssetId
    ) public virtual {
        string memory root = vm.projectRoot();
        newConfigPath = string.concat(root, newConfigPath);
        initializeConfigFromArgs(
            ctmProxy,
            bytecodesSupplier,
            rollupDAManager,
            create2FactorySalt,
            newConfigPath,
            governance,
            zkTokenAssetId
        );

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
        // Only override the salt when explicitly provided (non-zero).
        // When zero, the script falls back to the CREATE2_FACTORY_SALT env var or built-in default.
        if (permanentConfig.create2FactorySalt != bytes32(0)) {
            setCreate2Salt(permanentConfig.create2FactorySalt);
        }
        config.l1ChainId = block.chainid;
        newConfig.ctm = permanentConfig.ctmProxy;

        // The supplier is read off the CTM's `L1_BYTECODES_SUPPLIER()` immutable during discovery, so the
        // permanent-values entry is informational for this path.
        setAddressesBasedOnCTM();
        // Only ZKsync OS CTMs can be upgraded onto this release; the flag stays in the permanent
        // config as a guard against pointing the script at a legacy EraVM CTM section.
        // Must be non-zero: `InteropCenter.initL2` reverts on a zero asset ID. It runs on the genesis path
        // of `performForceDeployedContractsInit` only, so this aborts the genesis of chains created from the
        // release rather than this upgrade — caught here so the misconfiguration surfaces during
        // preparation instead of at a chain's creation.
        require(permanentConfig.zkTokenAssetId != bytes32(0), "zkTokenAssetId must be non-zero");
        config.zkTokenAssetId = permanentConfig.zkTokenAssetId;
        config.contracts.chainCreationParams = chainCreationParams;

        address ctmGov = ctmGovernance();
        if (governance != address(0)) {
            config.ownerAddress = governance;
        } else {
            config.ownerAddress = ctmGov;
        }
        newConfig.ecosystemAdminAddress = ctmGov;
        config.contracts.governanceSecurityCouncilAddress = Governance(payable(ctmGov)).securityCouncil();
        // config.contracts.governanceMinDelay = Governance(payable(ctmAddresses.admin.governance)).minDelay();
        config.contracts.validatorTimelockExecutionDelay = IValidatorTimelock(
            ctmAddresses.stateTransition.proxies.validatorTimelock
        ).executionDelay();
        config.testnetVerifier = UpgradeUtils.resolveTestnetVerifier(
            IChainTypeManager(ctmAddresses.stateTransition.proxies.chainTypeManager)
        );
        config.contracts.maxNumberOfChains = bridgehub.MAX_NUMBER_OF_ZK_CHAINS();
    }

    function initializeConfigFromArgs(
        address ctmProxy,
        address bytecodesSupplier,
        address rollupDAManager,
        bytes32 create2FactorySalt,
        string memory newConfigPath,
        address governance,
        bytes32 zkTokenAssetId
    ) internal virtual {
        string memory toml = vm.readFile(newConfigPath);

        // No `era_chain_id` read: `setAddressesBasedOnCTM` resolves it from the live asset router,
        // which is authoritative for the ecosystems this flow upgrades.

        PermanentCTMConfig memory permanentConfig = PermanentCTMConfig({
            ctmProxy: ctmProxy,
            bytecodesSupplier: bytecodesSupplier,
            create2FactorySalt: create2FactorySalt,
            zkTokenAssetId: zkTokenAssetId
        });
        ChainCreationParamsConfig memory chainCreationParams = getChainCreationParamsConfig(Utils.genesisConfigPath());

        // Optional explicit target protocol version from the upgrade input. The genesis config
        // (`configs/genesis/*/latest.json`) may still declare the PREVIOUS version while an
        // upgrade to the next one is being prepared, so the upgrade-env preset can pin the
        // packed version the emitted `setNewVersionUpgrade` must carry.
        if (toml.keyExists("$.contracts.latest_protocol_version")) {
            chainCreationParams.latestProtocolVersion = toml.readUint("$.contracts.latest_protocol_version");
        }

        // Optional override for pre-v32 introspection selection
        if (toml.keyExists("$.pre_v32_introspection")) {
            newConfig.hasPreV32IntrospectionOverride = true;
            newConfig.usePreV32IntrospectionOverride = toml.readBool("$.pre_v32_introspection");
        }

        initializeConfig(chainCreationParams, permanentConfig, governance);

        // Read governance upgrade timer initial delay from config
        if (toml.keyExists("$.governance_upgrade_timer_initial_delay")) {
            newConfig.governanceUpgradeTimerInitialDelay = toml.readUint("$.governance_upgrade_timer_initial_delay");
        }

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
        publishBytecodes();
        console.log("Bytecodes published!");
        deployStateTransitionDiamondFacets();
        generateUpgradeData();
        console.log("Upgrade data generated!");
        deployUpgradeObjects();
        composeUpgradeCut();
        saveOutput(upgradeConfig.outputPath);
    }

    /// @notice The upgrade objects of the CTM side. The default deploys the upgrade engine the
    ///         transition pins and then the transition of this edge; the bootstrap edge deploys its
    ///         migration instead.
    function deployUpgradeObjects() public virtual {
        ctmAddresses.stateTransition.defaultUpgrade = deployUsedUpgradeContract();
        deployCTMTransition();
    }

    /// @notice Deploys the write-once `CTMTransition` of this upgrade — what governance reviews and
    ///         what the three executor calls name. Everything it pins is a deployment of this run
    ///         or bound live state; nothing is authored calldata.
    /// @dev Rides the CREATE2 factory like every prepare deployment: the Safe bundle replays factory
    ///      transactions only.
    function deployCTMTransition() public virtual {
        address ctm = ctmAddresses.stateTransition.proxies.chainTypeManager;
        address fromRelease = IChainTypeManager(ctm).currentRelease();
        require(fromRelease != address(0), "CTM has no current release: the bootstrap edge must run first");
        address newRelease = ctmAddresses.stateTransition.currentRelease;
        require(newRelease != address(0), "new release not deployed");
        address engine = ctmAddresses.stateTransition.defaultUpgrade;
        require(engine != address(0), "upgrade engine not deployed");
        require(upgradeAddresses.upgradeTimer != address(0), "upgrade timer not deployed");
        PinnedContract memory coreRegistryPin;
        if (upgradeAddresses.coreRegistry != address(0)) {
            coreRegistryPin = _pin(upgradeAddresses.coreRegistry);
        }
        TransitionManifest memory manifest = TransitionManifest({
            oldProtocolVersion: getOldProtocolVersion(),
            newProtocolVersion: getNewProtocolVersion(),
            fromRelease: fromRelease,
            newRelease: newRelease,
            upgradeEngine: _pin(engine),
            proxyUpgrades: _ctmProxyUpgradeRows(),
            oldProtocolVersionDeadline: UpgradeHelperLib.getOldProtocolDeadline(),
            upgradeTimestamp: 0,
            l2Plan: transitionAuthoredL2Plan(),
            coreRegistry: coreRegistryPin,
            upgradeTimer: _pin(upgradeAddresses.upgradeTimer)
        });
        // From the build ARTIFACT, which is also where the bound executor's `TRANSITION_CODEHASH`
        // came from — see {BytecodeUtils.getDeployedBytecodeHash}.
        upgradeAddresses.ctmTransition = deployViaCreate2AndNotify(
            BytecodeUtils.readBytecodeL1("CTMTransition.sol", "CTMTransition"),
            abi.encode(manifest),
            "CTMTransition"
        );
        // Fail here, not in stage 0: every pin the object carries must hold against the live deployment.
        require(
            ICTMTransition(upgradeAddresses.ctmTransition).verifyAll(),
            "transition does not verify against the live deployment"
        );
        _requireObjectsMatchExecutorPins();
    }

    /// @notice Checks the objects this prepare hands to the executors against the codehashes those
    ///         executors were CONSTRUCTED with — the type-provenance gate of `stage0` and
    ///         `applyL1Upgrade`, evaluated at prepare time.
    /// @dev These immutables were set when the executors were deployed, possibly by an earlier
    ///      release's prepare. Nothing keeps a later build's artifact byte-identical to that one, so
    ///      a drifted object would otherwise only surface as a stage-0 revert with the whole upgrade
    ///      already reviewed and scheduled.
    function _requireObjectsMatchExecutorPins() internal view virtual {
        CTMUpgradeExecutor executor = CTMUpgradeExecutor(payable(boundCTMUpgradeExecutor()));
        require(
            upgradeAddresses.ctmTransition.codehash == executor.TRANSITION_CODEHASH(),
            "the deployed transition does not run the code the bound CTM executor pins"
        );
        if (upgradeAddresses.coreRegistry != address(0)) {
            require(
                upgradeAddresses.coreRegistry.codehash == executor.ECOSYSTEM_EXECUTOR().CORE_REGISTRY_CODEHASH(),
                "the core prepare's registry does not run the code the ecosystem executor pins"
            );
        }
    }

    /// @notice The enum-indexed CTM-domain inventory of this edge: a source-checked row for every
    ///         proxy this run deployed a new implementation for, every other slot an explicit inert
    ///         zero. The ServerNotifier row names its own (ChainAdmin-owned) ProxyAdmin.
    function _ctmProxyUpgradeRows() internal view virtual returns (ProxyUpgradeRow[] memory rows) {
        rows = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        rows[uint256(CTMContract.ChainTypeManager)] = _ctmRow(
            ctmAddresses.stateTransition.proxies.chainTypeManager,
            ctmAddresses.stateTransition.implementations.chainTypeManager,
            ProxyAdmin(address(0))
        );
        rows[uint256(CTMContract.ValidatorTimelock)] = _ctmRow(
            ctmAddresses.stateTransition.proxies.validatorTimelock,
            ctmAddresses.stateTransition.implementations.validatorTimelock,
            ProxyAdmin(address(0))
        );
        address notifierImplNew = ctmAddresses.stateTransition.implementations.serverNotifier;
        if (notifierImplNew != address(0)) {
            address notifierProxy = ctmAddresses.stateTransition.proxies.serverNotifier;
            rows[uint256(CTMContract.ServerNotifier)] = _ctmRow(
                notifierProxy,
                notifierImplNew,
                ProxyAdmin(Utils.getProxyAdminAddress(notifierProxy))
            );
        }
    }

    /// @dev The inert (all-zero) row when this run deployed no implementation for the proxy.
    function _ctmRow(
        address _proxy,
        address _implNew,
        ProxyAdmin _admin
    ) internal view returns (ProxyUpgradeRow memory row) {
        if (_implNew == address(0)) {
            return row;
        }
        return
            ProxyUpgradeRow({
                proxy: _proxy,
                expectedOldImpl: Utils.getImplementation(_proxy),
                implNew: PinnedContract({addr: _implNew, codehash: _implNew.codehash}),
                callInitializeUpgrade: false,
                admin: _admin
            });
    }

    /// @notice The authored L2 remainder of the transition. The default is an L1-only edge — no
    ///         extra deployment, no delegate, no composer, no factory dependency. A version whose L2
    ///         built-ins change derives their rows from the release pair on-chain and MUST author the
    ///         delegate that initializes them (the v34 bootstrap shows the shape).
    function transitionAuthoredL2Plan() internal virtual returns (AuthoredL2Plan memory) {
        return
            AuthoredL2Plan({
                extraDeployments: new IComplexUpgrader.UniversalContractUpgradeInfo[](0),
                delegateTo: address(0),
                delegateComposer: PinnedContract({addr: address(0), codehash: bytes32(0)}),
                factoryDepHashes: new uint256[](0)
            });
    }

    /// @notice The cut chains execute for this edge, as the CTM serves it (`upgradeCutForVersion`):
    ///         no facet cuts, the pinned engine's `upgradeFromTransition(transition)` init. Written
    ///         to the output for tooling; nothing is hand-composed.
    function composeUpgradeCut() public virtual {
        require(upgradeAddresses.ctmTransition != address(0), "transition not deployed");
        Diamond.DiamondCutData memory cut = CTMUpgradeComposer.buildUpgradeCutData(
            ctmAddresses.stateTransition.defaultUpgrade,
            abi.encodeCall(IDefaultUpgrade.upgradeFromTransition, (upgradeAddresses.ctmTransition))
        );
        newlyGeneratedData.upgradeCutData = abi.encode(cut);
        upgradeConfig.upgradeCutPrepared = true;
    }

    /// @notice The `RegistryBootstrapMigration` this run deploys, or zero for every edge that is
    ///         not a bootstrap.
    /// @dev Exists so `saveOutput` can NAME the migration: a bootstrap's stage calls target it,
    ///      but it is not reachable from any other reported address, and a reviewer should not
    ///      have to decode stage-1 calldata to find the object the edge runs.
    function bootstrapMigrationAddress() public view virtual returns (address) {
        return address(0);
    }

    /// @notice The CTM domain's bound `CTMUpgradeExecutor`: the CTM's owner once the bootstrap edge
    ///         has handed the domain over. The three governance calls of this upgrade target it and
    ///         the upgrade timer is bound to it.
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

    /// @notice Who may start this upgrade's timer: the bound executor (`stage0` starts it). The
    ///         bootstrap edge, which predates the executor, has governance start it.
    function timerGovernance() internal view virtual returns (address) {
        return boundCTMUpgradeExecutor();
    }

    function _pin(address _addr) internal view returns (PinnedContract memory) {
        require(_addr.code.length != 0, "pinned contract has no code");
        return PinnedContract({addr: _addr, codehash: _addr.codehash});
    }

    /// @notice The `CoreRegistry` of this upgrade (a core-prepare output). Set from the prepare params
    ///         in production; in-forge harnesses that drive both prepares call it directly.
    function setCoreRegistry(address _coreRegistry) public virtual {
        upgradeAddresses.coreRegistry = _coreRegistry;
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
    ///      {DeployCTMUtils._deployReleaseMember}: the six facets, `DiamondInit` and
    ///      `EIP7702Checker`. The verifier is not among them — a version that replaces it does so
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

    /// @notice One line per declared external action (see {ExternalActionsLib.describe}).
    function externalActionDescriptions() public view returns (string[] memory) {
        return externalActions.describe();
    }

    /// @notice The per-chain upgrade engine the transition pins. The repository is ZKsync-OS-only, so
    ///         the default is the ZKsync OS engine (it performs the per-chain rewrite of an L2 leg and
    ///         leaves an L1-only edge's all-zero L2 transaction alone).
    function deployUsedUpgradeContract() internal virtual returns (address) {
        return deploySimpleContract("DefaultUpgradeZKsyncOS");
    }

    function deployGovernanceUpgradeTimer() internal virtual {
        upgradeAddresses.upgradeTimer = deploySimpleContract("GovernanceUpgradeTimer");
    }

    /// @notice Deploy everything that should be deployed: the timer of this upgrade and what the
    ///         release deploy (`deployStateTransitionDiamondFacets`) needs first — the EIP-7702
    ///         checker the fresh MailboxFacet takes, and the force-deployments blob the release pins.
    function deployNewCTMContracts() public virtual {
        deployGovernanceUpgradeTimer();
        deployEIP7702Checker();
        getFixedForceDeploymentsData();
    }

    /// @notice The CTM domain's governance. Once the bootstrap edge has handed the domain to the
    ///         bound executor, the CTM's owner IS that executor and governance is its owner; the
    ///         bootstrap prepare (which runs before that handover) overrides this with the CTM's
    ///         owner itself.
    function ctmGovernance() internal view virtual returns (address) {
        return IOwnable(boundCTMUpgradeExecutor()).owner();
    }

    function deployUpgradeSpecificContractsL1() internal virtual {
        // Empty by default.
    }

    /// @notice Generate data required for the upgrade.
    /// @dev The chain-CREATION cut is deliberately not recomputed here: from v34 the CTM builds it
    ///      per chain creation from its pinned release, so an upgrade prepare has nothing to say
    ///      about it (see the retired `diamond_cut_data` output field).
    function generateUpgradeData() public virtual {
        require(upgradeConfig.initialized, "Not initialized");
        // TODO Return the require after getting the version from bridgehub
        //        require(upgradeConfig.ecosystemContractsDeployed, "Ecosystem contracts not deployed");

        // Important, this must come after the initializeExpectedL2Addresses
        getFixedForceDeploymentsData();
        console.log("Generated fixed force deployments data");
    }

    function getOwnerAddress() public virtual returns (address) {
        return config.ownerAddress;
    }

    /// @notice The ecosystem executor of this upgrade (a core-prepare output). Set from the prepare
    ///         params in production; in-forge harnesses that drive both prepares call it directly.
    function setEcosystemUpgradeExecutor(address _ecosystemUpgradeExecutor) public virtual {
        upgradeAddresses.ecosystemUpgradeExecutor = _ecosystemUpgradeExecutor;
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

    /// @notice This function is meant to only be used in tests
    function prepareCreateNewChainCall(uint256 chainId) public view virtual returns (Call[] memory result) {
        require(coreAddresses.bridgehub.proxies.bridgehub != address(0), "bridgehubProxyAddress is zero in newConfig");

        bytes32 newChainAssetId = L1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub).baseTokenAssetId(
            upToDateZkChain.chainId
        );
        result = new Call[](1);
        result[0] = Call({
            target: coreAddresses.bridgehub.proxies.bridgehub,
            value: 0,
            data: abi.encodeCall(
                IL1Bridgehub.createNewChain,
                (chainId, ctmAddresses.stateTransition.proxies.chainTypeManager, newChainAssetId, msg.sender)
            )
        });
    }

    function setAddressesBasedOnCTM() internal virtual {
        address ctm = newConfig.ctm;

        // Verify CTM contract exists
        require(ctm.code.length > 0, "CTM contract does not exist at specified address");

        // CTM exists - get bridgehub and determine which introspection to use
        address bridgehubAddr = ChainTypeManagerBase(ctm).BRIDGE_HUB();
        bridgehub = L1Bridgehub(bridgehubAddr);

        bool preV32Ecosystem;
        if (newConfig.hasPreV32IntrospectionOverride) {
            preV32Ecosystem = newConfig.usePreV32IntrospectionOverride;
        } else if (!AddressIntrospector.hasRegisteredChains(bridgehubAddr)) {
            // A chainless ecosystem has no protocol version to inspect. It cannot have been upgraded into
            // existence either, so it was deployed from scratch with the current contracts.
            preV32Ecosystem = false;
        } else {
            preV32Ecosystem = AddressIntrospector.shouldUsePreV32Introspection(bridgehubAddr);
        }

        if (preV32Ecosystem) {
            ctmAddresses = AddressIntrospector.getCTMAddressesV31(ctm);
            coreAddresses = AddressIntrospector.getCoreDeployedAddressesV31(bridgehubAddr);
        } else {
            ctmAddresses = AddressIntrospector.getCTMAddresses(ChainTypeManagerBase(ctm));
            coreAddresses = AddressIntrospector.getCoreDeployedAddresses(bridgehubAddr);
        }

        config.ownerAddress = ctmAddresses.admin.governance;

        // `DiamondInit` is the genesis cut's INIT target, not a routed facet, so a chain's routing
        // cannot expose it and introspection leaves it zero. Its canonical source is the CTM's own
        // current release — without reading it there, every upgrade deploys a fresh one and moves
        // the release even when nothing about the release changed. A pre-registry CTM has no
        // release, so the bootstrap edge still deploys one.
        address liveRelease = ctmAddresses.stateTransition.currentRelease;
        if (liveRelease != address(0) && liveRelease.code.length != 0) {
            ctmAddresses.stateTransition.facets.diamondInit = ICTMRelease(liveRelease).diamondInit();
        }

        address representativeChain = AddressIntrospector.getRepresentativeZkChain(bridgehubAddr);
        if (representativeChain != address(0)) {
            discoveredRepresentativeZkChain = AddressIntrospector.getZkChainAddresses(IZKChain(representativeChain));
            ctmAddresses.daAddresses.daContracts.rollupSLDAValidator = discoveredRepresentativeZkChain.l1DAValidator;
        } else {
            // Chainless ecosystem (fresh deployment), use up-to-date addresses
            console.log("No registered chain in bridgehub, using up-to-date addresses");
        }

        upToDateZkChain = AddressIntrospector.getUptoDateZkChainAddresses(ChainTypeManagerBase(ctm));

        uint256 ctmProtocolVersion = IChainTypeManager(ctm).protocolVersion();
        newConfig.oldProtocolVersion = ctmProtocolVersion;
        require(
            ctmProtocolVersion != getNewProtocolVersion(),
            "The new protocol version is already present on the ChainTypeManager"
        );
    }

    function getFixedForceDeploymentsData() internal override returns (FixedForceDeploymentsData memory data) {
        if (upgradeConfig.fixedForceDeploymentsDataGenerated) {
            return abi.decode(generatedData.forceDeploymentsData, (FixedForceDeploymentsData));
        }

        require(config.ownerAddress != address(0), "owner not set");

        data = _buildForceDeploymentsData(config.ownerAddress);
        bytes memory encodedData = abi.encode(data);
        generatedData.forceDeploymentsData = encodedData;
        upgradeConfig.fixedForceDeploymentsDataGenerated = true;
    }

    /////////////////////////// Blockchain interactions ////////////////////////////

    bool skipFactoryDepsCheck = false;

    function setSkipFactoryDepsCheck_TestOnly(bool _skipFactoryDepsCheck) public virtual {
        skipFactoryDepsCheck = _skipFactoryDepsCheck;
    }

    function publishBytecodes() public virtual {
        bytes[] memory allDeps = CoreOnGatewayHelper.getFullListOfFactoryDependencies(
            getAdditionalFactoryDependencyContracts()
        );
        BytecodesSupplier supplier = BytecodesSupplier(ctmAddresses.stateTransition.proxies.bytecodesSupplier);

        PublishFactoryDepsResult memory result = BytecodePublisher.publishAndProcessFactoryDeps(supplier, allDeps);

        factoryDepsResult = result;
        upgradeConfig.factoryDepsPublished = true;
    }

    ////////////////////////////// Preparing calls /////////////////////////////////

    function prepareDefaultGovernanceCalls()
        public
        virtual
        returns (Call[] memory stage0Calls, Call[] memory stage1Calls, Call[] memory stage2Calls)
    {
        // Three bundles, each one executor call plus whatever a version script declared as an
        // external action for that stage (the bootstrap edge declares its whole edge).
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

    /// @notice The ServerNotifier's implementation swap, an ADMIN action (the notifier's ProxyAdmin
    ///         is ChainAdmin-owned, not governance-owned) emitted only when this run deployed a new
    ///         notifier implementation; the section is written either way so tooling reads one shape.
    function prepareDefaultCTMAdminCalls() public virtual returns (Call[] memory calls) {
        address serverNotifierProxyAdmin = Utils.getProxyAdminAddress(
            ctmAddresses.stateTransition.proxies.serverNotifier
        );
        address chainAdmin = IOwnable(serverNotifierProxyAdmin).owner();
        address chainAdminOwner = IOwnable(chainAdmin).owner();
        if (ctmAddresses.stateTransition.implementations.serverNotifier != address(0)) {
            calls = prepareUpgradeServerNotifierCall();
            declareExternalAction(
                ExternalActionsLib.PHASE_ADMIN,
                "ServerNotifier implementation swap (ctm_admin_calls)",
                "ChainAdmin (owner of the notifier's ProxyAdmin)",
                calls[0]
            );
        }
        vm.serializeAddress("ctm_admin_calls", "chain_admin", chainAdmin);
        vm.serializeAddress("ctm_admin_calls", "chain_admin_owner", chainAdminOwner);

        string memory ctmAdminCallsSerialized = vm.serializeBytes(
            "ctm_admin_calls",
            "server_notifier_upgrade",
            abi.encode(calls)
        );

        // See the note in prepareDefaultGovernanceCalls on why keyed writeToml is not used here.
        string memory updatedCtmAdminToml = vm.serializeString("root", "ctm_admin_calls", ctmAdminCallsSerialized);
        vm.writeToml(updatedCtmAdminToml, upgradeConfig.outputPath);
    }

    function prepareDefaultTestUpgradeCalls() public {
        (Call[] memory testUpgradeChainCall, address ZKChainAdmin) = TESTONLY_prepareTestUpgradeChainCall();
        vm.serializeAddress("test_upgrade_calls", "test_upgrade_chain_caller", ZKChainAdmin);
        vm.serializeBytes("test_upgrade_calls", "test_upgrade_chain", abi.encode(testUpgradeChainCall));
        (Call[] memory testCreateChainCall, address bridgehubAdmin) = TESTONLY_prepareCreateChainCall();
        vm.serializeAddress("test_upgrade_calls", "test_create_chain_caller", bridgehubAdmin);

        string memory testUpgradeCallsSerialized = vm.serializeBytes(
            "test_upgrade_calls",
            "test_create_chain",
            abi.encode(testCreateChainCall)
        );

        // See the note in prepareDefaultGovernanceCalls on why keyed writeToml is not used here.
        string memory updatedTestCallsToml = vm.serializeString(
            "root",
            "test_upgrade_calls",
            testUpgradeCallsSerialized
        );
        vm.writeToml(updatedTestCallsToml, upgradeConfig.outputPath);
    }

    function prepareUpgradeServerNotifierCall() public virtual returns (Call[] memory calls) {
        address serverNotifierProxyAdmin = Utils.getProxyAdminAddress(
            ctmAddresses.stateTransition.proxies.serverNotifier
        );

        Call memory call = Call({
            target: serverNotifierProxyAdmin,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (
                    ITransparentUpgradeableProxy(payable(ctmAddresses.stateTransition.proxies.serverNotifier)),
                    ctmAddresses.stateTransition.implementations.serverNotifier
                )
            ),
            value: 0
        });

        calls = new Call[](1);
        calls[0] = call;
    }

    /// @notice The governance stages of this upgrade: `CTMUpgradeExecutor.stageN(transition)` —
    ///         the executor holds the pause, starts the timer, applies the ecosystem leg then the
    ///         CTM leg and restores — followed by whatever a version script declared as an
    ///         external action for the stage. A bootstrap prepare (no transition) emits only its
    ///         declared actions.
    function prepareStage0GovernanceCalls() public virtual returns (Call[] memory calls) {
        return
            _stageCalls(
                ExternalActionsLib.PHASE_STAGE_0,
                abi.encodeCall(CTMUpgradeExecutor.stage0, (ICTMTransition(upgradeAddresses.ctmTransition)))
            );
    }

    function prepareStage1GovernanceCalls() public virtual returns (Call[] memory calls) {
        return
            _stageCalls(
                ExternalActionsLib.PHASE_STAGE_1,
                abi.encodeCall(CTMUpgradeExecutor.stage1, (ICTMTransition(upgradeAddresses.ctmTransition)))
            );
    }

    function prepareStage2GovernanceCalls() public virtual returns (Call[] memory calls) {
        return
            _stageCalls(
                ExternalActionsLib.PHASE_STAGE_2,
                abi.encodeCall(CTMUpgradeExecutor.stage2, (ICTMTransition(upgradeAddresses.ctmTransition)))
            );
    }

    function _stageCalls(
        string memory _phase,
        bytes memory _executorCalldata
    ) internal view returns (Call[] memory calls) {
        Call[] memory declared = externalActions.callsForPhase(_phase);
        if (upgradeAddresses.ctmTransition == address(0)) {
            return declared;
        }
        calls = new Call[](declared.length + 1);
        calls[0] = Call({target: boundCTMUpgradeExecutor(), data: _executorCalldata, value: 0});
        uint256 length = declared.length;
        for (uint256 i = 0; i < length; ++i) {
            calls[i + 1] = declared[i];
        }
    }

    function getAddresses() public view override returns (CTMDeployedAddresses memory) {
        return ctmAddresses;
    }

    /// @notice Tests that it is possible to upgrade a chain to the new version
    function TESTONLY_prepareTestUpgradeChainCall() private view returns (Call[] memory calls, address admin) {
        address chainDiamondProxyAddress = L1Bridgehub(coreAddresses.bridgehub.proxies.bridgehub).getZKChain(
            upToDateZkChain.chainId
        );
        uint256 oldProtocolVersion = getOldProtocolVersion();
        Diamond.DiamondCutData memory upgradeCutData = abi.decode(
            getChainUpgradeDiamondCutData(),
            (Diamond.DiamondCutData)
        );
        admin = IZKChain(chainDiamondProxyAddress).getAdmin();
        // Each protocol generation exposes a different `upgradeChainFromVersion` on the chain
        // diamond; calling the wrong one hits the DiamondProxy fallback and reverts with "F".
        bytes memory upgradeCallData = UpgradeChainCall.encode(
            chainDiamondProxyAddress,
            oldProtocolVersion,
            upgradeCutData
        );
        calls = new Call[](1);
        calls[0] = Call({target: chainDiamondProxyAddress, data: upgradeCallData, value: 0});
    }

    /// @notice Tests that it is possible to create a new chain with the new version
    function getDefaultTestCreateChainId() public view virtual returns (uint256) {
        return ZKSYNC_OS_TEST_CREATE_CHAIN_ID;
    }

    function TESTONLY_prepareCreateChainCall() private returns (Call[] memory calls, address admin) {
        admin = getBridgehubAdmin();
        calls = new Call[](1);
        calls[0] = prepareCreateNewChainCall(getDefaultTestCreateChainId())[0];
    }

    function getCreationCalldata(string memory contractName) internal view virtual override returns (bytes memory) {
        if (compareStrings(contractName, "GovernanceUpgradeTimer")) {
            uint256 initialDelay = newConfig.governanceUpgradeTimerInitialDelay;
            uint256 maxAdditionalDelay = 2 weeks;
            return abi.encode(initialDelay, maxAdditionalDelay, timerGovernance(), newConfig.ecosystemAdminAddress);
        } else {
            return super.getCreationCalldata(contractName);
        }
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
        // Also save as state_transition_implementation_addr for backwards compatibility with zkstack CLI
        vm.serializeAddress(
            "state_transition",
            "state_transition_implementation_addr",
            ctmAddresses.stateTransition.implementations.chainTypeManager
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
        // Introspection reports the engine as zero (nothing on-chain to read it from), so an
        // unassigned engine surviving to serialization means the prepare never deployed one —
        // downstream that zero silently becomes a dead upgrade cut.
        require(ctmAddresses.stateTransition.defaultUpgrade != address(0), "default upgrade not deployed");
        string memory stateTransition = vm.serializeAddress(
            "state_transition",
            "default_upgrade_addr",
            ctmAddresses.stateTransition.defaultUpgrade
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
        vm.serializeAddress(
            "deployed_addresses",
            "l1_rollup_da_manager",
            ctmAddresses.daAddresses.daContracts.rollupDAManager
        );
        if (upgradeAddresses.upgradeStageValidator != address(0)) {
            vm.serializeAddress(
                "deployed_addresses",
                "upgrade_stage_validator",
                upgradeAddresses.upgradeStageValidator
            );
        }

        string memory deployedAddresses = vm.serializeAddress(
            "deployed_addresses",
            "l1_governance_upgrade_timer",
            upgradeAddresses.upgradeTimer
        );

        vm.serializeAddress("admin", "timer_governance_addr", timerGovernance());
        string memory admin = vm.serializeAddress("admin", "ecosystem_admin_addr", newConfig.ecosystemAdminAddress);

        // Serialize generated upgrade data. There is no `diamond_cut_data`: the chain-creation cut
        // is the CTM's own function of its pinned release, not a prepare output.
        vm.serializeBytes("contracts_newConfig", "force_deployments_data", generatedData.forceDeploymentsData);

        // Serialize protocol version info (needed for upgrade)
        vm.serializeUint("contracts_newConfig", "new_protocol_version", getNewProtocolVersion());
        vm.serializeUint(
            "contracts_newConfig",
            "governance_upgrade_timer_initial_delay",
            newConfig.governanceUpgradeTimerInitialDelay
        );
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
        vm.serializeString("root", "admin", admin);
        // The upgrade objects of this run — what governance reviews and the stage calls name.
        vm.serializeAddress("registry", "ctm_transition_addr", upgradeAddresses.ctmTransition);
        vm.serializeAddress("registry", "ctm_release_addr", ctmAddresses.stateTransition.currentRelease);
        vm.serializeAddress("registry", "upgrade_timer_addr", upgradeAddresses.upgradeTimer);
        vm.serializeAddress("registry", "core_registry_addr", upgradeAddresses.coreRegistry);
        address bootstrapMigrationAddr = bootstrapMigrationAddress();
        vm.serializeAddress("registry", "bootstrap_migration_addr", bootstrapMigrationAddr);
        // `ctm_upgrade_executor_addr` stays gated on the transition: protocol-ops reads a nonzero
        // value there as "this prepare's stage calls ARE executor calls", which a bootstrap's are
        // not (they are the two handovers and `migrate()`). The executor still has to be named,
        // so it gets its own ungated key. Only the v34 override is safe to call pre-bootstrap —
        // the default reads the CTM's live owner, which is not yet an executor.
        bool executorKnown = upgradeAddresses.ctmTransition != address(0) || bootstrapMigrationAddr != address(0);
        vm.serializeAddress(
            "registry",
            "bound_ctm_upgrade_executor_addr",
            executorKnown ? boundCTMUpgradeExecutor() : address(0)
        );
        string memory registry = vm.serializeAddress(
            "registry",
            "ctm_upgrade_executor_addr",
            upgradeAddresses.ctmTransition == address(0) ? address(0) : boundCTMUpgradeExecutor()
        );
        vm.serializeString("root", "registry", registry);
        string memory toml = vm.serializeBytes("root", "chain_upgrade_diamond_cut", newlyGeneratedData.upgradeCutData);

        vm.writeToml(toml, outputPath);
    }

    function getCTMAddress() public view returns (address) {
        return newConfig.ctm;
    }

    function getChainUpgradeDiamondCutData() public view returns (bytes memory) {
        require(upgradeConfig.upgradeCutPrepared, "upgrade cut data not prepared");
        return newlyGeneratedData.upgradeCutData;
    }

    ////////////////////////////// Misc utils /////////////////////////////////

    // add this to be excluded from coverage report
    function test() internal override {}
}
