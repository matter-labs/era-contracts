// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {Call} from "contracts/governance/Common.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {
    AuthoredL2Plan,
    BootstrapManifest,
    PinnedContract,
    ProxyUpgradeRow
} from "contracts/upgrades/registry/RegistryTypes.sol";
import {
    CTM_CONTRACT_COUNT,
    CTMContract,
    L2EcosystemContract
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {DefaultCTMUpgrade} from "../default-upgrade/DefaultCTMUpgrade.s.sol";
import {ExternalActionsLib} from "../default-upgrade/ExternalActionsLib.sol";
import {PinnedRegistryObject} from "../default-upgrade/PinnedRegistryObject.sol";
import {UpgradeHelperLib} from "../default-upgrade/UpgradeHelperLib.sol";
import {DeployCTML1OrGateway} from "../../ctm/DeployCTML1OrGateway.sol";
import {Utils} from "../../utils/Utils.sol";

/// @notice The v34 CTM upgrade: the ONE-TIME edge into the registry-driven model (see the
///         Bootstrap section of {docs/registry-driven-upgrades.md}). Chains crossing this edge
///         run pre-v34 facets and take the committed cut by hand, but the cut itself already
///         has the registry shape: NO facet cuts, just the `BootstrapUpgradeZKsyncOS` init,
///         which derives the facet reinstall on-chain from the pinned genesis release. The
///         stage-1 CTM call soup is GONE too: everything the CTM must do (its own
///         implementation swap, the version commit, the provenance anchors, the authority
///         handover) is pinned in a write-once `RegistryBootstrapMigration` deployed at prepare
///         time, and executed by its single `migrate()` call. Governance reviews a manifest and
///         FOUR calls — nominate the CTM, hand over its ProxyAdmin, migrate, accept — and every
///         later upgrade is a `CTMTransition` under the bound `CTMUpgradeExecutor`.
contract CTMUpgrade_v34 is DefaultCTMUpgrade {
    /// @notice The bound executor the whole CTM domain lands under. Deployed by this prepare
    ///         run; its address rides the bootstrap manifest (pinned + binding-checked there).
    CTMUpgradeExecutor public ctmUpgradeExecutor;

    /// @notice The write-once edge object. Its manifest pins everything the stage-1 calls used
    ///         to spell out.
    RegistryBootstrapMigration public bootstrapMigration;

    /// @notice The v34 delegate-calldata composer the bootstrap manifest pins: the CODE that
    ///         defines what `L2V34Upgrade` is called with.
    address public l2DelegateComposer;

    /// @notice The bootstrap edge deploys no transition: its objects are the bound executor and the
    ///         write-once migration. The committed cut is READ from the migration — the object
    ///         composes it on-chain from its pinned inputs, so the prepare has nothing to compose
    ///         and nothing to keep in step.
    function deployUpgradeObjects() public virtual override {
        deployRegistryBootstrap();
        _declareBootstrapActions();
    }

    /// @notice The cut chains crossing this edge take by hand, exactly as the migration commits it.
    ///         Written to the output for tooling; the bytes come from the object.
    function composeUpgradeCut() public virtual override {
        require(address(bootstrapMigration) != address(0), "bootstrap migration not deployed");
        newlyGeneratedData.upgradeCutData = abi.encode(bootstrapMigration.upgradeCut());
        upgradeConfig.upgradeCutPrepared = true;
    }

    /// @notice The bootstrap edge authors a COMPLETE release for a pre-registry ecosystem, so
    ///         every member is expected to be new — the live ones belong to the departing,
    ///         pre-v34 deployment.
    function changedReleaseMembers() internal view virtual override returns (string[] memory members) {
        members = new string[](8);
        members[0] = "ExecutorFacet";
        members[1] = "AdminFacet";
        members[2] = "MailboxFacet";
        members[3] = "GettersFacet";
        members[4] = "MigratorFacet";
        members[5] = "CommitterFacet";
        members[6] = "DiamondInit";
        members[7] = "EIP7702Checker";
    }

    /// @notice The executor this run deploys — the CTM's owner only once `migrate()` has run.
    function boundCTMUpgradeExecutor() public view virtual override returns (address) {
        require(address(ctmUpgradeExecutor) != address(0), "CTM executor not deployed");
        return address(ctmUpgradeExecutor);
    }

    /// @notice Governance starts the bootstrap's timer itself (stage 0): the executor that starts
    ///         every later upgrade's timer does not hold the domain yet.
    function timerGovernance() internal view virtual override returns (address) {
        return config.ownerAddress;
    }

    /// @notice Before the bootstrap edge, governance owns the CTM directly.
    function ctmGovernance() internal view virtual override returns (address) {
        return ctmAddresses.admin.governance;
    }

    /// @notice The upgrade engine — the composed cut's init delegatecall target, pinned by the
    ///         bootstrap manifest through `upgradeCutInitCodehash`. Deployed HERE, not in
    ///         `deployNewCTMContracts`: the engine pins the genesis release as an immutable, and
    ///         the release only exists once `deployStateTransitionDiamondFacets` has run.
    function generateUpgradeData() public virtual override {
        ctmAddresses.stateTransition.defaultUpgrade = deployUsedUpgradeContract();
        super.generateUpgradeData();
    }

    /// @dev The repo is ZKsync-OS-only: every CTM this prepare runs against is a ZKsync OS CTM.
    function deployUsedUpgradeContract() internal virtual override returns (address) {
        // The bootstrap engine: derives the facet reinstall on-chain from the genesis release it
        // pins as an immutable, then runs the storage/L2 part of `DefaultUpgradeZKsyncOS`.
        return deploySimpleContract("BootstrapUpgradeZKsyncOS");
    }

    /// @notice The L2 delegate's bytecode is a factory dependency of the upgrade transaction like
    ///         the built-ins' — published by this prepare, so the sequencer has its preimage when
    ///         the unsafe deployment below runs. (The bootstrap object refuses a plan that installs
    ///         a bytecode its factory dependencies do not carry.)
    function getAdditionalFactoryDependencyContracts()
        internal
        pure
        override
        returns (L2EcosystemContract[] memory additionalDependencyContracts)
    {
        additionalDependencyContracts = new L2EcosystemContract[](1);
        additionalDependencyContracts[0] = L2EcosystemContract.L2V34Upgrade;
    }

    /// @notice The L2 delegate (`L2V34Upgrade`) rides the upgrade tx itself as an unsafe force
    ///         deployment at a bytecode-derived address, so it never overwrites live code.
    function getAdditionalUniversalForceDeployments()
        internal
        override
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory additional)
    {
        bytes memory bytecodeInfo = Utils.getZKOSBytecodeInfoForContract("L2V34Upgrade.sol", "L2V34Upgrade");
        additional = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        additional[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
            deployedBytecodeInfo: bytecodeInfo,
            newAddress: L2GenesisForceDeploymentsHelper.generateRandomAddress(bytecodeInfo)
        });
    }

    function deployNewCTMContracts() public virtual override {
        super.deployNewCTMContracts();
        // Bootstrap-only: the stage-2 "migrations unpaused" read. Recurring upgrades check pause
        // state on-chain in `CTMUpgradeExecutor.stage2`.
        upgradeAddresses.upgradeStageValidator = deploySimpleContract("UpgradeStageValidator");

        // The new ChainTypeManager implementation (per VM) — the bootstrap manifest's one
        // participating inventory row.
        (, string memory ctmContractName) = DeployCTML1OrGateway.resolve(CTMContract.ChainTypeManager);
        ctmAddresses.stateTransition.implementations.chainTypeManager = deploySimpleContract(ctmContractName);

        // Named in the bootstrap manifest under its own chainAdmin-owned ProxyAdmin (see
        // `_bootstrapManifest`); the swap itself still rides the CTM-admin operational calls.
        ctmAddresses.stateTransition.implementations.serverNotifier = deploySimpleContract("ServerNotifier");
    }

    /// @notice Deploys the bound executor and the write-once migration pinned to this prepare
    ///         run's outputs.
    function deployRegistryBootstrap() public virtual {
        address ctmProxy = ctmAddresses.stateTransition.proxies.chainTypeManager;
        require(ctmProxy != address(0), "CTM proxy is zero");
        // The admin that ACTUALLY owns the CTM proxy (and the per-CTM proxies), read from the
        // live EIP-1967 slot rather than any address book — the migration validates every row
        // against it, so a stale book entry would fail loudly at the wrong time.
        ProxyAdmin ctmProxyAdmin = ProxyAdmin(Utils.getProxyAdminAddress(ctmProxy));
        // The two-executor model hands the CTM domain's admin to the CTM executor and the
        // ecosystem's to the ecosystem executor — a SHARED admin cannot be handed to both, and
        // the collision would only surface as a stage-1 revert. ZKsyncOS CTMs (the only ones
        // this release upgrades) are deployed with their own admin; Era CTMs on old ecosystems
        // share the ecosystem's and would need an admin split first.
        require(
            address(ctmProxyAdmin) != coreAddresses.shared.transparentProxyAdmin,
            "CTM domain shares the ecosystem ProxyAdmin; split the admin before the bootstrap"
        );

        // Both go through the CREATE2 factory like every other prepare deployment: the Safe
        // bundle replays only factory transactions, so a plain CREATE here would leave the
        // stage-1 `migrate()`/`acceptCTMOwnership()` calls pointing at codeless addresses on
        // the real chain (a call to code-less address is a silent success).
        ctmUpgradeExecutor = CTMUpgradeExecutor(
            payable(
                deployViaCreate2AndNotify(
                    type(CTMUpgradeExecutor).creationCode,
                    abi.encode(
                        getOwnerAddress(),
                        IChainTypeManager(ctmProxy),
                        ctmProxyAdmin,
                        // The ecosystem executor the core prepare of this upgrade deployed — the
                        // bound route for every future transition's ecosystem leg.
                        ecosystemUpgradeExecutor(),
                        // The audited-object anchor for every FUTURE transition this executor
                        // accepts, taken from the artifact those transitions are DEPLOYED from
                        // (see {PinnedRegistryObject}).
                        PinnedRegistryObject.codehash("CTMTransition.sol", "CTMTransition")
                    ),
                    "CTMUpgradeExecutor"
                )
            )
        );

        l2DelegateComposer = deploySimpleContract("L2V34DelegateCalldataComposer");

        bootstrapMigration = RegistryBootstrapMigration(
            deployViaCreate2AndNotify(
                type(RegistryBootstrapMigration).creationCode,
                abi.encode(_bootstrapManifest(ctmProxy, ctmProxyAdmin)),
                "RegistryBootstrapMigration"
            )
        );
    }

    function getCreationCalldata(string memory contractName) internal view virtual override returns (bytes memory) {
        if (compareStrings(contractName, "L2V34DelegateCalldataComposer")) {
            return abi.encode();
        }
        if (compareStrings(contractName, "UpgradeStageValidator")) {
            return abi.encode(ctmAddresses.stateTransition.proxies.chainTypeManager, getNewProtocolVersion());
        }
        return super.getCreationCalldata(contractName);
    }

    function _bootstrapManifest(
        address _ctmProxy,
        ProxyAdmin _ctmProxyAdmin
    ) internal returns (BootstrapManifest memory manifest) {
        address implNew = ctmAddresses.stateTransition.implementations.chainTypeManager;
        require(implNew != address(0), "new CTM implementation not deployed");
        address release = ctmAddresses.stateTransition.currentRelease;
        require(release != address(0), "current release not deployed");

        // The one participating slot of the enum-indexed CTM-domain inventory: the CTM's own
        // implementation swap. Every other slot stays inert (explicitly not upgraded) — the
        // per-CTM proxies keep their implementations across this edge.
        ProxyUpgradeRow[] memory proxyUpgrades = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        proxyUpgrades[uint256(CTMContract.ChainTypeManager)] = ProxyUpgradeRow({
            proxy: _ctmProxy,
            expectedOldImpl: Utils.getImplementation(_ctmProxy),
            implNew: PinnedContract({addr: implNew, codehash: implNew.codehash}),
            callInitializeUpgrade: false,
            admin: ProxyAdmin(address(0))
        });
        // The ServerNotifier rides the same reviewed inventory, under the admin that actually
        // administers it (its own chainAdmin-owned ProxyAdmin). The migration does not own that
        // admin, so `migrate()` leaves the row to the ChainAdmin — the operational
        // `ctm_admin_calls` this prepare also emits — and `validateApplied()` requires it applied.
        address notifierProxy = ctmAddresses.stateTransition.proxies.serverNotifier;
        address notifierImplNew = ctmAddresses.stateTransition.implementations.serverNotifier;
        require(notifierImplNew != address(0), "new ServerNotifier implementation not deployed");
        proxyUpgrades[uint256(CTMContract.ServerNotifier)] = ProxyUpgradeRow({
            proxy: notifierProxy,
            expectedOldImpl: Utils.getImplementation(notifierProxy),
            implNew: PinnedContract({addr: notifierImplNew, codehash: notifierImplNew.codehash}),
            callInitializeUpgrade: false,
            admin: ProxyAdmin(Utils.getProxyAdminAddress(notifierProxy))
        });

        address engine = ctmAddresses.stateTransition.defaultUpgrade;
        require(engine != address(0), "bootstrap engine not deployed");

        manifest = BootstrapManifest({
            ctm: _ctmProxy,
            expectedProtocolVersion: getOldProtocolVersion(),
            ctmProxyAdmin: _ctmProxyAdmin,
            proxyUpgrades: proxyUpgrades,
            currentRelease: PinnedContract({addr: release, codehash: release.codehash}),
            newProtocolVersion: getNewProtocolVersion(),
            oldProtocolVersionDeadline: UpgradeHelperLib.getOldProtocolDeadline(),
            upgradeEngine: PinnedContract({addr: engine, codehash: engine.codehash}),
            l2Plan: bootstrapAuthoredL2Plan(),
            upgradeTimestamp: 0,
            ctmExecutor: PinnedContract({
                addr: address(ctmUpgradeExecutor),
                codehash: address(ctmUpgradeExecutor).codehash
            }),
            upgradeTimer: PinnedContract({
                addr: upgradeAddresses.upgradeTimer,
                codehash: upgradeAddresses.upgradeTimer.codehash
            })
        });
    }

    /// @notice The authored L2 remainder of the bootstrap edge: the delegate's unsafe deployment
    ///         (its address derived from the bytecode info), the pinned composer that defines its
    ///         arguments, and the published factory dependencies. The table-derived set comes from
    ///         the pinned genesis release, on-chain.
    /// @dev Virtual so bytecode-light test harnesses can substitute an L1-only edge: the real plan
    ///      reads the `L2V34Upgrade` artifact.
    function bootstrapAuthoredL2Plan() internal virtual returns (AuthoredL2Plan memory) {
        require(l2DelegateComposer != address(0), "L2 delegate composer not deployed");
        bytes memory delegateInfo = Utils.getZKOSBytecodeInfoForContract("L2V34Upgrade.sol", "L2V34Upgrade");
        return
            AuthoredL2Plan({
                extraDeployments: getAdditionalUniversalForceDeployments(),
                delegateTo: L2GenesisForceDeploymentsHelper.generateRandomAddress(delegateInfo),
                delegateComposer: PinnedContract({addr: l2DelegateComposer, codehash: l2DelegateComposer.codehash}),
                factoryDepHashes: factoryDepsResult.factoryDepsHashes
            });
    }

    /// @notice Every governance call of the bootstrap edge's CTM leg, declared as the external
    ///         action it is: this edge predates the transition lifecycle, so governance starts the
    ///         timer, hands both CTM-domain authorities to the migration and runs it (`migrate()` is
    ///         permissionless — the handover IS the approval — but rides the bundle so the edge is
    ///         applied atomically with it), then gates on the migration's post-state check and
    ///         performs the two bootstrap-JOIN authorizations the recurring lifecycle needs and the
    ///         executor cannot grant itself. The validator's timer/pause pre-checks of the legacy
    ///         stage 1 are absorbed: `migrate()` checks the pinned timer's deadline itself, and the
    ///         CTM's version-edge commit refuses to run while migrations are unpaused.
    function _declareBootstrapActions() internal virtual {
        require(address(bootstrapMigration) != address(0), "bootstrap migration not deployed");
        require(upgradeAddresses.upgradeTimer != address(0), "upgradeTimer is zero");
        require(upgradeAddresses.upgradeStageValidator != address(0), "upgradeStageValidator is zero");
        string memory governance = "protocol governance (CTM owner)";
        address ctmProxy = ctmAddresses.stateTransition.proxies.chainTypeManager;
        address ctmProxyAdmin = Utils.getProxyAdminAddress(ctmProxy);
        declareExternalAction(
            ExternalActionsLib.PHASE_STAGE_0,
            "start the pinned upgrade timer",
            governance,
            Call({
                target: upgradeAddresses.upgradeTimer,
                data: abi.encodeCall(GovernanceUpgradeTimer.startTimer, ()),
                value: 0
            })
        );
        declareExternalAction(
            ExternalActionsLib.PHASE_STAGE_1,
            "nominate the bootstrap migration as CTM owner",
            governance,
            Call({
                target: ctmProxy,
                data: abi.encodeCall(Ownable2Step.transferOwnership, (address(bootstrapMigration))),
                value: 0
            })
        );
        declareExternalAction(
            ExternalActionsLib.PHASE_STAGE_1,
            "hand the CTM-domain ProxyAdmin to the bootstrap migration",
            "CTM-domain ProxyAdmin owner (governance)",
            Call({
                target: ctmProxyAdmin,
                data: abi.encodeCall(Ownable2Step.transferOwnership, (address(bootstrapMigration))),
                value: 0
            })
        );
        declareExternalAction(
            ExternalActionsLib.PHASE_STAGE_1,
            "run the bootstrap edge (migrate)",
            "permissionless, state-gated (both authorities held, timer passed, pins hold)",
            Call({target: address(bootstrapMigration), data: abi.encodeCall(bootstrapMigration.migrate, ()), value: 0})
        );
        declareExternalAction(
            ExternalActionsLib.PHASE_STAGE_2,
            "bootstrap post-state gate (validateApplied)",
            "any (view)",
            Call({
                target: address(bootstrapMigration),
                data: abi.encodeCall(bootstrapMigration.validateApplied, ()),
                value: 0
            })
        );
        address chainAssetHandler = IBridgehubBase(coreAddresses.bridgehub.proxies.bridgehub).chainAssetHandler();
        declareExternalAction(
            ExternalActionsLib.PHASE_STAGE_2,
            "register the CTM executor as an upgrade pauser on the shared ChainAssetHandler",
            "ChainAssetHandler owner (governance)",
            Call({
                target: chainAssetHandler,
                data: abi.encodeCall(IChainAssetHandlerBase.setUpgradePauser, (address(ctmUpgradeExecutor), true)),
                value: 0
            })
        );
        declareExternalAction(
            ExternalActionsLib.PHASE_STAGE_2,
            "authorize the CTM executor on the ecosystem executor",
            "ecosystem executor owner (governance)",
            Call({
                target: address(ecosystemUpgradeExecutor()),
                data: abi.encodeCall(
                    EcosystemUpgradeExecutor.setCTMExecutorAuthorization,
                    (address(ctmUpgradeExecutor), true)
                ),
                value: 0
            })
        );
        declareExternalAction(
            ExternalActionsLib.PHASE_STAGE_2,
            "check chain migrations are unpaused again",
            "any (view)",
            Call({
                target: upgradeAddresses.upgradeStageValidator,
                data: abi.encodeCall(UpgradeStageValidator.checkMigrationsUnpaused, ()),
                value: 0
            })
        );
    }

    /// @notice The `EcosystemUpgradeExecutor` the core prepare of this upgrade deployed — an input
    ///         of this prepare (`CTMUpgradeParams.ecosystemUpgradeExecutor`, read by protocol-ops
    ///         from the core output TOML), checked to exist so a stale or missing input fails here
    ///         instead of in stage 2.
    function ecosystemUpgradeExecutor() public view returns (EcosystemUpgradeExecutor) {
        address executor = upgradeAddresses.ecosystemUpgradeExecutor;
        require(executor != address(0), "ecosystem executor not set (core prepare output)");
        require(executor.code.length != 0, "ecosystem executor has no code");
        return EcosystemUpgradeExecutor(payable(executor));
    }
}
