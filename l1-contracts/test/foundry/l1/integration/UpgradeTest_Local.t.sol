// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable gas-custom-errors

import {CTMUpgrade_v36} from "../../../../deploy-scripts/upgrade/v36/CTMUpgrade_v36.s.sol";
import {CoreUpgrade_v36} from "../../../../deploy-scripts/upgrade/v36/CoreUpgrade_v36.s.sol";
import {DefaultCoreUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultCoreUpgrade.s.sol";
import {
    AuthoredL2Side,
    DefaultCTMUpgrade
} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {DefaultChainUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultChainUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {L2_ECOSYSTEM_CONTRACT_COUNT} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {UpgradeIntegrationTestBase} from "./UpgradeTestShared.t.sol";
import {PreviousReleaseFixture} from "./utils/PreviousReleaseFixture.sol";
import {EcosystemUpgradeParams} from "../../../../deploy-scripts/upgrade/default-upgrade/UpgradeParams.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {Utils as DeployScriptUtils} from "../../../../deploy-scripts/utils/Utils.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {IBootstrapUpgrade} from "contracts/upgrades/IBootstrapUpgrade.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ChainRouting} from "test-utils/ChainRouting.sol";
import {IL1GenesisUpgrade} from "contracts/upgrades/IL1GenesisUpgrade.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {RegistryPostState} from "../unit/concrete/Upgrades/registry/RegistryPostState.sol";
import {L2CanonicalTransactionLib} from "contracts/state-transition/libraries/L2CanonicalTransactionLib.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {BootstrapManifest, ProxyUpgradeRow, ReleaseManifest} from "contracts/upgrades/registry/RegistryTypes.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {ContractsBytecodesLib} from "../../../../deploy-scripts/utils/bytecode/ContractsBytecodesLib.sol";
import {CTMContract} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {L1InteropFeeManager} from "contracts/core/interop-fee/L1InteropFeeManager.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";

/// @notice Test-only v35 CTM upgrade with the same MemoryOOG mocks as the v32 local harness
///         (the heavy JSON/zkout reads live on the shared base). The bootstrap flow itself —
///         the migration deploy, the one governance bundle, the legacy cut-taking commit — runs
///         UNMOCKED: that is what this file exists to test.
contract CTMUpgradeForLocalTest is CTMUpgrade_v36 {
    /// @dev Same MemoryOOG avoidance: the real builder reads every L2 contract's bytecode.
    ///      Correct length, empty rows — and no shell, since no row sits behind one.
    function getL2BytecodeInfoTable() internal pure override returns (bytes[] memory) {
        return new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT);
    }

    function getL2SystemProxyBytecodeInfo() internal pure override returns (bytes memory) {
        return "";
    }

    /// @dev This fixture is L1-only: no L2 leg is relayed, and the real side's artifact reads (the
    ///      delegate's and every built-in's bytecode) are MemoryOOG here. The base's default — an
    ///      empty plan over the empty table above and nothing to publish — is an L1-only edge, for
    ///      which the migration composes the all-zero L2 transaction.
    function authorL2Side() internal override returns (AuthoredL2Side memory) {
        return DefaultCTMUpgrade.authorL2Side();
    }
}

/// @notice Chain leg of the bootstrap edge for a chain whose admin does not act: the CTM owner
///         crosses it through its checked cut-taking passthrough, which hands the committed cut to
///         the chain's pre-v35 entrypoint.
/// @dev Pranks the CTM's owner, the CTM executor that governance drives through `forward`.
contract ChainUpgradeByCTMOwnerForLocalTest is DefaultChainUpgrade {
    function upgradeChain(Diamond.DiamondCutData memory diamondCutData) public override {
        ChainTypeManager ctm = ChainTypeManager(IZKChain(config.chainDiamondProxyAddress).getChainTypeManager());
        vm.prank(ctm.owner());
        ctm.upgradeChainFromVersion(config.chainChainId, config.oldProtocolVersion, diamondCutData);
    }
}

/// @notice The fixture the v35 BOOTSTRAP edge leaves behind, built through the real prepare
///         pipeline over the previous release's frozen L1 state (see {PreviousReleaseFixture}):
///         `CTMUpgrade_v36` deploying the executor + `RegistryBootstrapMigration`, the one governance
///         bundle `RegistryBootstrapSequence` derives (the notifier accept, the ecosystem handover and
///         core leg, nominate the CTM, hand over its ProxyAdmin, `migrate()` — which itself completes
///         the executor's accept — and the completion check) performing the whole edge, and an
///         L1-settled chain of that release crossing it through its own pre-v35 Admin facet.
/// @dev Abstract so the post-bootstrap state can be reused: it is the only in-forge fixture whose
///      ecosystem is registry-driven, which is what a RECURRING prepare needs to run against (see
///      `UpgradeTestRecurring_Local.t.sol`). Heavy execution + event assertions run in
///      `setUp -> internalTest()` (RAM constraint).
abstract contract UpgradeIntegrationBootstrapFixture is
    UpgradeIntegrationTestBase,
    PreviousReleaseFixture,
    RegistryPostState
{
    using stdToml for string;

    /// @dev The release's own local upgrade input, which protocol-ops' default prepare reads: it names no
    ///      target version, so the edge goes to the genesis version. Moved by `yarn new-release`.
    string internal constant RELEASE_UPGRADE_INPUT = "/upgrade-envs/v0.36.0-v36/local.toml";

    /// @dev The previous release's L1-settled chain that crosses the edge.
    uint256 internal constant UPGRADED_CHAIN_ID = 10;

    PreviousRelease internal previousRelease;

    /// @dev The genesis engine the previous release's CTM ran before the edge.
    address internal genesisEngineBeforeUpgrade;

    /// @dev The upgraded chain's RollupDAManager before the edge, which the prepare builds the new
    ///      AdminFacet over.
    address internal rollupDAManagerBeforeUpgrade;

    function createCoreUpgrade() internal override returns (DefaultCoreUpgrade) {
        return new CoreUpgrade_v36();
    }

    function createCTMUpgrade() internal override returns (DefaultCTMUpgrade) {
        return new CTMUpgradeForLocalTest();
    }

    function createChainUpgrade() internal virtual override returns (DefaultChainUpgrade) {
        return new DefaultChainUpgrade();
    }

    function _ecosystemUpgradeParams() internal view override returns (EcosystemUpgradeParams memory) {
        return
            EcosystemUpgradeParams({
                bridgehubProxyAddress: previousRelease.bridgehub,
                ctmProxy: previousRelease.chainTypeManager,
                // The env input names none, so protocol-ops resolves it from a chain on the CTM; the
                // prepare's CTM discovery leaves it zero.
                rollupDAManager: rollupDAManagerBeforeUpgrade,
                create2FactorySalt: UPGRADE_CREATE2_FACTORY_SALT,
                upgradeInputPath: ECOSYSTEM_UPGRADE_INPUT,
                ecosystemOutputPath: ECOSYSTEM_OUTPUT,
                governance: previousRelease.governance,
                // Dummy asset ID is fine for these tests — fixed-ZK-fee bundles are not exercised.
                zkTokenAssetId: bytes32(uint256(1))
            });
    }

    function setUp() public virtual {
        previousRelease = _loadPreviousRelease();
        FixtureChain memory chain = _fixtureChain(previousRelease, UPGRADED_CHAIN_ID);
        _prepareSettlement(chain);
        _settleBatch(chain);
        _installChainAdmin(chain);
        _handAuthorityToGovernance(previousRelease);
        chainId = UPGRADED_CHAIN_ID;
        genesisEngineBeforeUpgrade = IChainTypeManager(previousRelease.chainTypeManager).l1GenesisUpgrade();
        rollupDAManagerBeforeUpgrade = IAdmin(chain.diamondProxy).getRollupDAManager();

        ECOSYSTEM_UPGRADE_INPUT = RELEASE_UPGRADE_INPUT;
        ECOSYSTEM_OUTPUT = "/script-out/foundry-upgrade/local-v35-core-out.toml";
        CTM_OUTPUT = "/script-out/foundry-upgrade/local-v35-ctm.toml";
        CORE_OUTPUT = "/script-out/foundry-upgrade/local-v35-core.toml";
        setupUpgrade();

        address bridgehub = coreUpgrade.getDiscoveredBridgehub().proxies.bridgehub;
        bytes32 baseTokenAssetId = IBridgehubBase(bridgehub).baseTokenAssetId(chainId);
        _expectedBaseTokenAssetId = baseTokenAssetId;
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.baseTokenAssetId, 0), abi.encode(baseTokenAssetId));

        internalTest();
    }
}

/// @notice The bootstrap edge's own assertions over the fixture above: the version bump, the
///         authority handover to the bound executor, and the legacy commit shape.
contract UpgradeIntegrationTestLocal is UpgradeIntegrationBootstrapFixture {
    using stdToml for string;

    /// @notice Every object the bootstrap prepare deploys is reproducible from the build
    ///         artifact's creation code and the constructor arguments the reviewed package and
    ///         manifest record — the derivation `protocol-ops ecosystem verify-bootstrap` performs
    ///         (`construction::constructor_args`) over the same artifacts, every argument taken
    ///         from where the verifier takes it. Pinned in a real EVM over a real prepare run: a
    ///         prepare that passes an argument the constructor does not take (as this one once
    ///         did) deploys fine and is unreproducible from the constructor's own arguments.
    function test_bootstrapObjectsAreReproducibleFromTheirReviewedArguments() public view {
        CTMUpgradeForLocalTest bootstrap = CTMUpgradeForLocalTest(address(ctmUpgrade));
        string memory root = vm.projectRoot();
        string memory coreOutput = vm.readFile(string.concat(root, CORE_OUTPUT));
        string memory ctmOutput = vm.readFile(string.concat(root, CTM_OUTPUT));
        (, bytes32 coreSalt) = coreUpgrade.getCreate2FactoryParams();
        (, bytes32 ctmSalt) = ctmUpgrade.getCreate2FactoryParams();

        BootstrapManifest memory manifest = bootstrap.bootstrapMigration().getManifest();
        address coreExecutor = coreOutput.readAddress("$.registry.core_upgrade_executor_addr");
        address ecosystemProxyAdmin = coreOutput.readAddress("$.upgrade_addresses.shared.transparent_proxy_admin");

        // The package summary the verifier cross-checks against the manifest.
        assertEq(coreExecutor, manifest.coreExecutor, "the manifest names the core prepare's executor");
        assertEq(ctmOutput.readAddress("$.registry.ctm_upgrade_executor_addr"), manifest.ctmExecutor);
        assertEq(
            ctmOutput.readAddress("$.registry.ctm_infrastructure_transition_addr"),
            address(0),
            "a bootstrap's CTM rows ride its migration"
        );
        assertEq(ctmOutput.readAddress("$.registry.ctm_transition_addr"), address(0), "a bootstrap has no transition");
        assertEq(ctmOutput.readAddress("$.registry.bootstrap_migration_addr"), address(bootstrap.bootstrapMigration()));
        assertEq(ctmOutput.readAddress("$.state_transition.chain_type_manager_proxy"), manifest.ctm);
        assertEq(
            ctmOutput.readAddress("$.deployed_addresses.transparent_proxy_admin"),
            address(manifest.ctmProxyAdmin)
        );
        // Each leg records the salt it deployed under, so the verifier re-derives the objects below
        // without a reviewer-supplied salt.
        assertEq(coreOutput.readBytes32("$.create2_factory_salt"), coreSalt, "the core leg's salt");
        assertEq(ctmOutput.readBytes32("$.create2_factory_salt"), ctmSalt, "the CTM leg's salt");

        // The executors' construction record (`[upgrade_executors]`), which protocol-ops re-derives each
        // executor from after its owner moves: the ORIGINAL constructor arguments and salt.
        assertEq(coreOutput.readAddress("$.upgrade_executors.core_executor.address"), coreExecutor);
        assertEq(coreOutput.readBytes32("$.upgrade_executors.core_executor.create2_salt"), coreSalt);
        assertEq(coreOutput.readAddress("$.upgrade_executors.core_executor.initial_owner"), manifest.governance);
        assertEq(coreOutput.readAddress("$.upgrade_executors.core_executor.proxy_admin"), ecosystemProxyAdmin);
        assertFalse(vm.keyExistsToml(coreOutput, "$.upgrade_executors.coordinator"), "no coordinator is recorded");
        assertEq(ctmOutput.readAddress("$.upgrade_executors.ctm_executor.address"), manifest.ctmExecutor);
        assertEq(ctmOutput.readBytes32("$.upgrade_executors.ctm_executor.create2_salt"), ctmSalt);
        assertEq(ctmOutput.readAddress("$.upgrade_executors.ctm_executor.initial_owner"), manifest.governance);
        assertEq(ctmOutput.readAddress("$.upgrade_executors.ctm_executor.chain_type_manager"), manifest.ctm);
        assertEq(
            ctmOutput.readAddress("$.upgrade_executors.ctm_executor.ctm_proxy_admin"),
            address(manifest.ctmProxyAdmin)
        );

        // The core leg, under the core prepare's salt.
        assertEq(
            DeployScriptUtils.canonicalCreate2Address(
                coreSalt,
                vm.getCode("CoreUpgradeExecutor.sol:CoreUpgradeExecutor"),
                abi.encode(manifest.governance, ecosystemProxyAdmin)
            ),
            coreExecutor,
            "the core executor re-derives from the reviewed owner and the ecosystem ProxyAdmin"
        );
        assertEq(
            DeployScriptUtils.canonicalCreate2Address(
                coreSalt,
                vm.getCode("ProxyUpgradeTransition.sol:ProxyUpgradeTransition"),
                abi.encode(coreUpgrade.coreTransition().getManifest())
            ),
            address(coreUpgrade.coreTransition()),
            "the core transition re-derives from the manifest it serves"
        );

        // The CTM leg, under the CTM prepare's salt.
        assertEq(
            DeployScriptUtils.canonicalCreate2Address(
                ctmSalt,
                vm.getCode("CTMUpgradeExecutor.sol:CTMUpgradeExecutor"),
                abi.encode(manifest.governance, manifest.ctm, manifest.ctmProxyAdmin)
            ),
            manifest.ctmExecutor,
            "the CTM executor re-derives from the manifest's owner and bindings"
        );
        assertEq(
            DeployScriptUtils.canonicalCreate2Address(
                ctmSalt,
                vm.getCode("RegistryBootstrapMigration.sol:RegistryBootstrapMigration"),
                abi.encode(manifest)
            ),
            address(bootstrap.bootstrapMigration()),
            "the migration re-derives from the manifest it serves"
        );
        assertEq(
            DeployScriptUtils.canonicalCreate2Address(
                ctmSalt,
                vm.getCode("RegistryBootstrapSequence.sol:RegistryBootstrapSequence"),
                abi.encode(address(bootstrap.bootstrapMigration()), address(coreUpgrade.coreTransition()))
            ),
            address(bootstrap.bootstrapSequence()),
            "the sequence re-derives from the migration and the core transition"
        );
    }

    /// @notice Every member the bootstrap prepare deploys carries a `[member_deployments]` record in
    ///         the output of the leg that deployed it, and re-derives from it: the build artifact's
    ///         creation code and the recorded constructor arguments, under the recorded salt through
    ///         the deterministic factory, land exactly at the member — the derivation
    ///         `protocol-ops ecosystem verify-bootstrap` performs (`member_construction`).
    function test_bootstrapMembersAreReproducibleFromTheirRecords() public view {
        CTMUpgradeForLocalTest bootstrap = CTMUpgradeForLocalTest(address(ctmUpgrade));
        string memory root = vm.projectRoot();
        string memory coreOutput = vm.readFile(string.concat(root, CORE_OUTPUT));
        string memory ctmOutput = vm.readFile(string.concat(root, CTM_OUTPUT));
        (, bytes32 coreSalt) = coreUpgrade.getCreate2FactoryParams();
        (, bytes32 ctmSalt) = ctmUpgrade.getCreate2FactoryParams();
        BootstrapManifest memory manifest = bootstrap.bootstrapMigration().getManifest();
        ReleaseManifest memory release = CTMRelease(manifest.currentRelease).getManifest();

        uint256 facets = release.genesisFacets.length;
        for (uint256 i = 0; i < facets; ++i) {
            (string memory name, bytes memory args) = _recordedMember(
                ctmOutput,
                ctmSalt,
                release.genesisFacets[i].facet
            );
            // The two immutables code identity cannot see, held at their source.
            if (keccak256(bytes(name)) == keccak256("AdminFacet")) {
                (uint256 l1ChainId, address rollupDAManager) = abi.decode(args, (uint256, address));
                assertEq(l1ChainId, block.chainid, "AdminFacet is built for this L1");
                assertNotEq(rollupDAManager, address(0), "AdminFacet is built over a RollupDAManager");
                assertEq(
                    rollupDAManager,
                    ctmUpgrade.getAddresses().daAddresses.daContracts.rollupDAManager,
                    "AdminFacet is built over the prepare's RollupDAManager"
                );
            } else if (keccak256(bytes(name)) == keccak256("MailboxFacet")) {
                (, , , bool isTestnet) = abi.decode(args, (uint256, address, address, bool));
                assertTrue(isTestnet, "MailboxFacet is built for the env's testnet verifier");
            }
        }
        _recordedMember(ctmOutput, ctmSalt, release.diamondInit);
        _recordedMember(ctmOutput, ctmSalt, release.genesisUpgrade);
        _recordedMember(ctmOutput, ctmSalt, manifest.upgradeEngine);
        // The prepare deploys the composer either way; this L1-only fixture's plan names none.
        assertEq(manifest.l2Plan.delegateComposer, address(0), "an L1-only plan names no composer");
        uint256 ctmRows = manifest.ctmProxyUpgrades.length;
        for (uint256 i = 0; i < ctmRows; ++i) {
            if (manifest.ctmProxyUpgrades[i].implNew != address(0)) {
                _recordedMember(ctmOutput, ctmSalt, manifest.ctmProxyUpgrades[i].implNew);
            }
        }
        ProxyUpgradeRow[] memory coreRows = coreUpgrade.coreTransition().getManifest().proxyUpgrades;
        uint256 coreRowCount = coreRows.length;
        for (uint256 i = 0; i < coreRowCount; ++i) {
            if (coreRows[i].implNew != address(0)) {
                _recordedMember(coreOutput, coreSalt, coreRows[i].implNew);
            }
        }
    }

    /// @dev The `[member_deployments]` record of `_member` in `_output`, re-derived: returns the
    ///      recorded contract and constructor arguments once they are proven to land at `_member`.
    function _recordedMember(
        string memory _output,
        bytes32 _salt,
        address _member
    ) private view returns (string memory name, bytes memory args) {
        string memory key = string.concat("$.member_deployments['", vm.toString(_member), "']");
        assertTrue(vm.keyExistsToml(_output, key), string.concat("no record of ", vm.toString(_member)));
        name = _output.readString(string.concat(key, ".contract"));
        args = _output.readBytes(string.concat(key, ".constructor_args"));
        assertEq(
            _output.readAddress(string.concat(key, ".create2_factory")),
            DeployScriptUtils.DETERMINISTIC_CREATE2_ADDRESS,
            "recorded through the deterministic factory"
        );
        assertEq(_output.readBytes32(string.concat(key, ".create2_salt")), _salt, "recorded under the leg's salt");
        assertEq(
            DeployScriptUtils.canonicalCreate2Address(_salt, ContractsBytecodesLib.getCreationCodeEVM(name), args),
            _member,
            string.concat(name, " re-derives from its record")
        );
    }

    function test_bootstrapUpgrade_Local() public {
        CTMUpgradeForLocalTest bootstrap = CTMUpgradeForLocalTest(address(ctmUpgrade));
        address ctm = ctmUpgrade.getCTMAddress();

        // Protocol version bumps, on the CTM and on the chain that crossed via the legacy leg.
        assertEq(IChainTypeManager(ctm).protocolVersion(), _expectedNewVersion, "CTM protocolVersion not bumped");
        assertEq(
            IGetters(_upgradedChainDiamond).getProtocolVersion(),
            _expectedNewVersion,
            "the chain did not cross the edge"
        );

        // The edge is one-shot and spent.
        assertTrue(bootstrap.bootstrapMigration().executed(), "migration must be spent");

        // The WHOLE CTM domain landed under the bound executor: CTM ownership (the accept runs
        // inside `migrate()` itself) and the CTM-domain ProxyAdmin.
        address executor = address(bootstrap.ctmUpgradeExecutor());
        assertEq(Ownable(ctm).owner(), executor, "CTM must be owned by the executor");
        assertEq(
            Ownable(DeployScriptUtils.getProxyAdminAddress(ctm)).owner(),
            executor,
            "CTM ProxyAdmin must be owned by the executor"
        );

        // The bootstrap commits the LEGACY cut-taking edge: the deprecated hash is written for
        // the departing version and no transition is registered (internalTest asserted the
        // matching event shape).
        assertTrue(_expectedUpgradeCutHash != bytes32(0), "bootstrap must commit a legacy cut hash");
        assertEq(
            IChainTypeManager(ctm).upgradeTransition(ctmUpgrade.getOldProtocolVersion()),
            address(0),
            "the bootstrap edge must not register a transition"
        );

        // The cut the prepare ships is the object's, and this asserts the BYTES rather than
        // re-running the composition: the committed hash comes from the CTM's own storage, and the
        // payload is read back field by field — the pinned engine as the init target, no facet
        // cuts, and an init that names the migration and nothing else. What the engine then read
        // from it shows on the upgraded chain: the version edge, the release's verifier, and (this
        // fixture is L1-only) no L2 protocol upgrade transaction.
        address release = IChainTypeManager(ctm).currentRelease();
        bytes memory shippedCut = ctmUpgrade.getChainUpgradeDiamondCutData();
        assertEq(keccak256(shippedCut), _expectedUpgradeCutHash, "the shipped cut must be the committed one");
        Diamond.DiamondCutData memory cut = abi.decode(shippedCut, (Diamond.DiamondCutData));
        assertEq(cut.facetCuts.length, 0, "the bootstrap cut carries no facet cuts");
        assertEq(cut.initAddress, bootstrap.committedUpgradeEngine(), "the init target is the pinned engine");
        assertEq(
            this.decodeUpgradeInit(cut.initCalldata),
            address(bootstrap.bootstrapMigration()),
            "the init names the pinned migration"
        );
        L2CanonicalTransaction memory l2Tx = bootstrap.bootstrapMigration().l2UpgradeTx(
            IGetters(_upgradedChainDiamond).getChainId()
        );
        assertEq(
            keccak256(abi.encode(l2Tx)),
            keccak256(abi.encode(L2CanonicalTransactionLib.emptyL2CanonicalTransaction())),
            "an L1-only edge composes the all-zero L2 transaction"
        );
        assertEq(
            address(IGetters(_upgradedChainDiamond).getVerifier()),
            ICTMRelease(release).verifier(),
            "the chain runs the pinned release's verifier"
        );
        assertEq(
            IGetters(_upgradedChainDiamond).getL2SystemContractsUpgradeTxHash(),
            bytes32(0),
            "no L2 protocol upgrade transaction on an L1-only edge"
        );
        assertTrue(
            ChainRouting.matchesRelease(ICTMRelease(release), _upgradedChainDiamond),
            "the bootstrap engine reinstalled exactly the release's routing"
        );
        assertEq(
            IAdmin(_upgradedChainDiamond).getRollupDAManager(),
            rollupDAManagerBeforeUpgrade,
            "the chain keeps its RollupDAManager across the edge"
        );

        // The genesis release is pinned as `currentRelease` (re-pointed to the release this
        // prepare run deployed).
        assertEq(release, bootstrap.getAddresses().stateTransition.currentRelease, "release must be the pipeline's");

        // The genesis engine is a release member like any other: the bootstrap replaces the
        // pre-v35 engine discovery reported, and the CTM serves the release's.
        (address releaseGenesisEngine, , ) = ICTMRelease(release).genesisParams();
        assertTrue(releaseGenesisEngine != genesisEngineBeforeUpgrade, "the release must not keep the pre-v35 engine");
        assertTrue(releaseGenesisEngine.code.length != 0, "the release's engine is deployed");
        assertEq(
            IChainTypeManager(ctm).l1GenesisUpgrade(),
            releaseGenesisEngine,
            "the CTM serves the release's engine"
        );
        assertEq(
            bootstrap.getAddresses().stateTransition.genesisUpgrade,
            releaseGenesisEngine,
            "the prepare reports the engine it pinned"
        );

        // New chain created AFTER the edge geneses from the pinned release at the new version, and
        // its genesis upgrade ran: the pending L2 transaction is exactly the one the release's
        // engine composes for it.
        assertTrue(_newChainDiamond != address(0), "new chain not registered");
        assertEq(IGetters(_newChainDiamond).getProtocolVersion(), _expectedNewVersion, "new chain wrong version");
        address bridgehub = coreUpgrade.getDiscoveredBridgehub().proxies.bridgehub;
        assertEq(
            IGetters(_newChainDiamond).getL2SystemContractsUpgradeTxHash(),
            keccak256(
                abi.encode(
                    IL1GenesisUpgrade(releaseGenesisEngine).genesisUpgradeTx(
                        release,
                        bridgehub,
                        NEW_CHAIN_ID,
                        _expectedNewVersion
                    )
                )
            ),
            "the new chain carries the release engine's genesis transaction"
        );

        _assertBootstrapJoinsTheRegistryModel(bootstrap, ctm, bridgehub, executor);
        _assertInteropFeeManagerDeployed(ctm, bridgehub);
        _assertBackfillWindowOpened(bridgehub);
    }

    /// @dev The vault's swap opened the backfill window of the chains registered before the upgrade, and only theirs
    ///      ({protocol-docs/interop-gating.md#backfill}).
    function _assertBackfillWindowOpened(address _bridgehub) private view {
        IL1NativeTokenVault nativeTokenVault = IL1NativeTokenVault(
            address(IL1AssetRouter(address(IBridgehubBase(_bridgehub).assetRouter())).nativeTokenVault())
        );
        assertTrue(nativeTokenVault.chainBalanceBackfillPending(chainId), "pre-upgrade chain not pending");
        assertFalse(nativeTokenVault.chainBalanceBackfillPending(NEW_CHAIN_ID), "new chain pending");
    }

    /// @dev The previous release's CTM has no interop fee manager: the edge deploys one, switched off, owned by
    ///      governance and behind the CTM's ProxyAdmin, and builds the new CTM implementation over it.
    function _assertInteropFeeManagerDeployed(address _ctm, address _bridgehub) private view {
        L1InteropFeeManager interopFeeManager = L1InteropFeeManager(
            ctmUpgrade.getAddresses().stateTransition.proxies.interopFeeManager
        );
        assertTrue(address(interopFeeManager).code.length != 0, "Upgrade deployed no interop fee manager");
        assertEq(
            IChainTypeManager(_ctm).L1_INTEROP_FEE_MANAGER(),
            address(interopFeeManager),
            "CTM points at another interop fee manager"
        );
        address governance = ctmUpgrade.getAddresses().admin.governance;
        assertEq(interopFeeManager.owner(), governance, "Interop fee manager not owned by governance");
        assertEq(interopFeeManager.pendingOwner(), address(0), "Interop fee manager has a pending owner");
        assertEq(
            DeployScriptUtils.getProxyAdminAddress(address(interopFeeManager)),
            DeployScriptUtils.getProxyAdminAddress(_ctm),
            "Interop fee manager not behind the CTM's ProxyAdmin"
        );
        assertEq(interopFeeManager.feeRecipient(), governance, "Interop fees not swept to governance");
        assertEq(interopFeeManager.feeToken(), ETH_TOKEN_ADDRESS, "Interop fee not charged in ether");
        assertEq(interopFeeManager.feePerUnit(), 0, "Interop fee not switched off");
        assertEq(address(interopFeeManager.BRIDGE_HUB()), _bridgehub, "Interop fee manager on another bridgehub");
    }

    /// @dev The whole bootstrap edge — both domains — is DERIVED from `RegistryBootstrapSequence`
    ///      and declared by the CTM prepare; the core prepare of this edge declares nothing, so the
    ///      merged bundle is exactly the object's. The harness already executed it green in
    ///      `internalTest`; this asserts the emitted shape (the notifier accept first, the ecosystem
    ///      handover and core leg, the completion check last), that the completion check holds, the
    ///      post-state the edge leaves, and the notifier handover.
    function _assertBootstrapJoinsTheRegistryModel(
        CTMUpgradeForLocalTest _bootstrap,
        address _ctm,
        address _bridgehub,
        address _executor
    ) private {
        address chainAssetHandler = IBridgehubBase(_bridgehub).chainAssetHandler();
        RegistryBootstrapMigration migration = _bootstrap.bootstrapMigration();
        address coreExecutor = address(coreUpgrade.getCoreUpgradeExecutor());
        Call[] memory bundle = _bootstrap.prepareGovernanceCalls();
        assertEq(
            bundle.length,
            7,
            "v35 bundle: the notifier accept, the core leg, the CTM handover, the edge, the completion check"
        );
        assertEq(bundle[0].target, _executor, "the notifier accept opens the bundle");
        assertEq(
            bundle[1].target,
            address(CoreUpgradeExecutor(payable(coreExecutor)).PROXY_ADMIN()),
            "then the ecosystem ProxyAdmin handover"
        );
        assertEq(bundle[2].target, coreExecutor, "then the core leg");
        assertEq(
            bundle[2].data,
            abi.encodeCall(CoreUpgradeExecutor.applyL1Upgrade, (coreUpgrade.coreTransition())),
            "applyL1Upgrade(coreTransition)"
        );
        assertEq(bundle[5].target, address(migration), "then the edge itself");
        assertEq(bundle[5].data, abi.encodeCall(RegistryBootstrapMigration.migrate, ()), "migrate()");
        assertEq(bundle[6].target, address(migration), "and the completion check closes it");
        assertEq(bundle[6].data, abi.encodeCall(RegistryBootstrapMigration.validateApplied, ()), "validateApplied()");
        assertEq(
            _bootstrap.externalActionEntries().length,
            9,
            "the CTM prepare declares the 7 derived governance calls and the 2 handover admin calls"
        );
        assertEq(coreUpgrade.externalActionEntries().length, 0, "the core prepare of a derived edge authors nothing");
        migration.validateApplied();
        _assertBootstrapApplied(migration);
        assertEq(_bootstrap.bootstrapSequence().MIGRATION(), address(migration), "the sequence names this edge");
        assertEq(
            IOwnable(address(CoreUpgradeExecutor(payable(coreExecutor)).PROXY_ADMIN())).owner(),
            coreExecutor,
            "the ecosystem ProxyAdmin landed under the core executor"
        );
        assertEq(IOwnable(_ctm).owner(), _executor, "the executor owns the CTM");
        assertFalse(
            IChainAssetHandlerBase(chainAssetHandler).migrationPausedFor(_ctm),
            "the bootstrap takes no migration pause"
        );

        // The ChainAdmin handed the notifier over (`ctm_admin_calls`), the bundle accepted it, and
        // `migrate()` swapped it through the CTM-domain ProxyAdmin like the CTM's own row.
        address notifierProxy = _bootstrap.getAddresses().stateTransition.proxies.serverNotifier;
        assertEq(
            DeployScriptUtils.getImplementation(notifierProxy),
            _bootstrap.getAddresses().stateTransition.implementations.serverNotifier,
            "the notifier runs the implementation its pinned row names"
        );
        assertEq(
            DeployScriptUtils.getProxyAdminAddress(notifierProxy),
            DeployScriptUtils.getProxyAdminAddress(_ctm),
            "the notifier sits under the CTM-domain ProxyAdmin"
        );
        assertEq(IOwnable(notifierProxy).owner(), _executor, "the notifier is the CTM executor's");

        // The timelock's row: the v35 Admin facet serves only the cut-reading upgrade call, which
        // the pre-v35 timelock does not forward.
        address timelockProxy = _bootstrap.getAddresses().stateTransition.proxies.validatorTimelock;
        ProxyUpgradeRow memory timelockRow = migration.getManifest().ctmProxyUpgrades[
            uint256(CTMContract.ValidatorTimelock)
        ];
        assertEq(timelockRow.proxy, timelockProxy, "the timelock row names the CTM's timelock");
        assertTrue(timelockRow.implNew != timelockRow.expectedOldImpl, "the timelock row swaps its implementation");
        assertEq(
            DeployScriptUtils.getImplementation(timelockProxy),
            timelockRow.implNew,
            "the timelock runs the implementation its pinned row names"
        );
        assertEq(
            timelockRow.implNew,
            _bootstrap.getAddresses().stateTransition.implementations.validatorTimelock,
            "the row installs the timelock the prepare deployed"
        );
    }

    /// @dev Decodes an `upgradeFromBootstrap(address)` init payload; external so the selector can
    ///      be sliced off calldata.
    function decodeUpgradeInit(bytes calldata _initCalldata) external pure returns (address) {
        require(
            bytes4(_initCalldata[:4]) == IBootstrapUpgrade.upgradeFromBootstrap.selector,
            "unexpected init selector"
        );
        return abi.decode(_initCalldata[4:], (address));
    }
}

/// @notice The bootstrap edge over the same fixture, with the lagging pre-v35 chain crossed by the
///         CTM owner instead of its admin (see {ChainUpgradeByCTMOwnerForLocalTest}).
contract UpgradeIntegrationTestLocalCTMOwnerCrossing is UpgradeIntegrationBootstrapFixture {
    function createChainUpgrade() internal override returns (DefaultChainUpgrade) {
        return new ChainUpgradeByCTMOwnerForLocalTest();
    }

    function test_theCTMOwnerCrossesAPreV35ChainOverTheBootstrapEdge() public view {
        address release = IChainTypeManager(ctmUpgrade.getCTMAddress()).currentRelease();
        assertEq(
            IGetters(_upgradedChainDiamond).getProtocolVersion(),
            _expectedNewVersion,
            "the chain crossed the edge"
        );
        assertEq(
            address(IGetters(_upgradedChainDiamond).getVerifier()),
            ICTMRelease(release).verifier(),
            "the chain runs the pinned release's verifier"
        );
        assertTrue(
            ChainRouting.matchesRelease(ICTMRelease(release), _upgradedChainDiamond),
            "the bootstrap engine reinstalled exactly the release's routing"
        );
    }
}
