// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";

import {CTMUpgrade_v34} from "../../../../deploy-scripts/upgrade/v34/CTMUpgrade_v34.s.sol";
import {CoreUpgrade_v34} from "../../../../deploy-scripts/upgrade/v34/CoreUpgrade_v34.s.sol";
import {DefaultCoreUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultCoreUpgrade.s.sol";
import {DefaultCTMUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {DefaultChainUpgrade} from "../../../../deploy-scripts/upgrade/default-upgrade/DefaultChainUpgrade.s.sol";
import {Call} from "contracts/governance/Common.sol";
import {L2_ECOSYSTEM_CONTRACT_COUNT} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {AuthoredL2Plan, PinnedContract} from "contracts/upgrades/registry/RegistryTypes.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {L1ContractDeployer} from "./_SharedL1ContractDeployer.t.sol";
import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";
import {TokenDeployer} from "./_SharedTokenDeployer.t.sol";
import {UpgradeIntegrationTestBase} from "./UpgradeTestShared.t.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {stdToml} from "forge-std/StdToml.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {LegacyTestAdminFacet} from "contracts/dev-contracts/test/LegacyTestAdminFacet.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {IAdminV31} from "../../../../deploy-scripts/utils/UpgradeChainCall.sol";
import {Utils as DeployScriptUtils} from "../../../../deploy-scripts/utils/Utils.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {UpgradeStageValidator} from "contracts/upgrades/UpgradeStageValidator.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ProposedUpgrade, ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";

/// @notice Test-only v34 CTM upgrade with the same MemoryOOG mocks as the v32 local harness
///         (the heavy JSON/zkout reads live on the shared base). The bootstrap flow itself —
///         the migration deploy, the four-call stage-1 leg, the legacy cut-taking commit — runs
///         UNMOCKED: that is what this file exists to test.
contract CTMUpgrade_v34_Test is CTMUpgrade_v34 {
    /// @dev The shared local fixture is Era-flavored, but the release's real engine
    ///      (`DefaultUpgradeZKsyncOS` + the `L2V34Upgrade` L2 leg) is ZKsyncOS-only. This
    ///      fixture asserts the L1 side only and never relays an L2 leg, so it runs the plain
    ///      `DefaultUpgrade`; the real engine is exercised by the anvil bootstrap pipeline.
    function deployUsedUpgradeContract() internal override returns (address) {
        return deploySimpleContract("DefaultUpgrade");
    }

    /// @dev Same MemoryOOG avoidance: the real builder reads every L2 contract's bytecode.
    ///      Correct length, empty rows.
    function getL2BytecodeInfoTable() internal override returns (bytes[] memory) {
        return new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT);
    }

    /// @dev This fixture is L1-only: no L2 leg is relayed, and the real plan's delegate-bytecode
    ///      read is MemoryOOG here. An empty authored remainder over the empty table above is an
    ///      L1-only edge, for which the migration composes the all-zero L2 transaction.
    function bootstrapAuthoredL2Plan() internal override returns (AuthoredL2Plan memory) {
        return
            AuthoredL2Plan({
                extraDeployments: new IComplexUpgrader.UniversalContractUpgradeInfo[](0),
                delegateTo: address(0),
                delegateComposer: PinnedContract({addr: address(0), codehash: bytes32(0)}),
                factoryDepHashes: new uint256[](0)
            });
    }

    /// @notice Nothing to publish for an L1-only edge (reading the real factory deps' JSON
    ///         artifacts is MemoryOOG here); the plan carries no dependencies either.
    function publishBytecodes() public override {
        console.log("Test mode: L1-only edge, no factory deps to publish");
        upgradeConfig.factoryDepsPublished = true;
    }
}

/// @notice The v34 core prepare needs no trimming in the local fixture.
contract CoreUpgrade_v34_Test is CoreUpgrade_v34 {}

/// @notice Chain leg of the bootstrap edge: the local baseline chain runs the CURRENT
///         (cut-READING) Admin facet, but the bootstrap commits the legacy cut-taking edge —
///         `upgradeTransition` stays zero for the departing version. The harness pre-installs
///         `LegacyTestAdminFacet` (the same dance the anvil bootstrap stage does), so the chain
///         crosses by HANDING the committed cut through the legacy 3-arg entrypoint, exactly
///         like production pre-v34 chains will.
contract ChainUpgrade_v34_Test is DefaultChainUpgrade {
    function upgradeChain(Diamond.DiamondCutData memory diamondCutData) public override {
        bytes memory callData = abi.encodeCall(
            IAdminV31.upgradeChainFromVersion,
            (config.chainDiamondProxyAddress, config.oldProtocolVersion, diamondCutData)
        );
        DeployScriptUtils.adminExecute(
            IZKChain(config.chainDiamondProxyAddress).getAdmin(),
            address(0),
            config.chainDiamondProxyAddress,
            callData,
            0
        );
    }
}

/// @notice Local (non-fork) test of the v34 BOOTSTRAP edge through the real prepare pipeline:
///         a fresh ecosystem + Era chain at the baseline version, `CTMUpgrade_v34` deploying
///         the executor + `RegistryBootstrapMigration`, and the collapsed three-call stage-1 leg
///         (nominate the CTM, hand over its ProxyAdmin, `migrate()` — which itself completes
///         the executor's accept) performing the whole edge. Complements the anvil two-stage
///         test: same flow, but
///         driven end to end by the production prepare script.
/// @dev Heavy execution + event assertions run in `setUp -> internalTest()` (RAM constraint);
///      the body checks persisted state — the version bump, the authority handover to the
///      bound executor, and the legacy commit shape.
contract UpgradeIntegrationTest_v34_Local is
    UpgradeIntegrationTestBase,
    L1ContractDeployer,
    ZKChainDeployer,
    TokenDeployer
{
    using stdToml for string;

    function createCoreUpgrade() internal override returns (DefaultCoreUpgrade) {
        return new CoreUpgrade_v34_Test();
    }

    function createCTMUpgrade() internal override returns (DefaultCTMUpgrade) {
        return new CTMUpgrade_v34_Test();
    }

    function createChainUpgrade() internal override returns (DefaultChainUpgrade) {
        return new ChainUpgrade_v34_Test();
    }

    /// @notice Bump the CTM's new protocol version from the upgrade input TOML so the local
    ///         baseline fixture exercises a real version transition.
    function afterInitHook() internal override {
        string memory root = vm.projectRoot();
        string memory upgradeToml = vm.readFile(string.concat(root, ECOSYSTEM_UPGRADE_INPUT));
        uint256 newProtocolVersion = upgradeToml.readUint("$.contracts.new_protocol_version");
        ctmUpgrade.setNewProtocolVersion(newProtocolVersion);
    }

    /// @dev Installs the pre-v34 cut-taking entrypoint on the baseline chain through the CTM
    ///      owner's `executeUpgrade` — the production path for owner-forced cuts — BEFORE the
    ///      CTM is handed to the migration. See {ChainUpgrade_v34_Test}.
    function _installLegacyCutTakingFacet() private {
        LegacyTestAdminFacet legacyFacet = new LegacyTestAdminFacet();
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = LegacyTestAdminFacet.upgradeChainFromVersion.selector;
        Diamond.FacetCut[] memory cuts = new Diamond.FacetCut[](1);
        cuts[0] = Diamond.FacetCut({
            facet: address(legacyFacet),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });
        Diamond.DiamondCutData memory addCut = Diamond.DiamondCutData({
            facetCuts: cuts,
            initAddress: address(0),
            initCalldata: hex""
        });

        address ctm = ctmUpgrade.getCTMAddress();
        vm.prank(Ownable(ctm).owner());
        IChainTypeManager(ctm).executeUpgrade(chainId, addCut);
    }

    /// @dev The local fixture is Era-shaped: the CTM proxy shares the ecosystem's
    ///      transparentProxyAdmin. Production ZKsyncOS CTMs sit under their OWN ProxyAdmin
    ///      (see upgrade-envs/v0.31.0-interopB), which the v34 bootstrap requires — the core
    ///      leg hands the ecosystem admin to the ecosystem executor, the CTM leg hands the
    ///      CTM-domain admin to the CTM executor. Model that shape by moving the CTM proxy
    ///      onto a fresh admin (owned by the same identity as the shared one) before prepare.
    function _splitCTMProxyAdmin() private {
        address ctm = address(addresses.chainTypeManager);
        ProxyAdmin sharedAdmin = ProxyAdmin(DeployScriptUtils.getProxyAdminAddress(ctm));
        address sharedAdminOwner = sharedAdmin.owner();

        ProxyAdmin ctmAdmin = new ProxyAdmin();
        ctmAdmin.transferOwnership(sharedAdminOwner);

        vm.prank(sharedAdminOwner);
        sharedAdmin.changeProxyAdmin(ITransparentUpgradeableProxy(payable(ctm)), address(ctmAdmin));
    }

    function setUp() public {
        console.log("setUp: Starting");
        _deployL1Contracts();
        _deployTokens();
        _registerNewTokens(tokens);

        _deployEra();
        chainId = eraZKChainId;
        acceptPendingAdmin();

        _splitCTMProxyAdmin();
        console.log("setUp: CTM proxy moved onto its own ProxyAdmin");

        ECOSYSTEM_UPGRADE_INPUT = "/upgrade-envs/foundry-upgrade.toml";
        ECOSYSTEM_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-l1.toml";
        ECOSYSTEM_OUTPUT = "/script-out/foundry-upgrade/local-v34-core-out.toml";
        CTM_INPUT = "/test/foundry/l1/integration/deploy-scripts/script-out/output-deploy-ctm.toml";
        CTM_OUTPUT = "/script-out/foundry-upgrade/local-v34-ctm.toml";
        CORE_OUTPUT = "/script-out/foundry-upgrade/local-v34-core.toml";
        console.log("setUp: Paths configured");
        setupUpgrade(true);
        console.log("setUp: Upgrade setup complete");

        _installLegacyCutTakingFacet();
        console.log("setUp: Legacy cut-taking facet installed");

        address bridgehub = coreUpgrade.getDiscoveredBridgehub().proxies.bridgehub;
        bytes32 eraBaseTokenAssetId = IBridgehubBase(bridgehub).baseTokenAssetId(eraZKChainId);
        _expectedBaseTokenAssetId = eraBaseTokenAssetId;
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.baseTokenAssetId, 0), abi.encode(eraBaseTokenAssetId));

        internalTest();
        console.log("setUp: Internal test complete");
    }

    function test_v34BootstrapUpgrade_Local() public {
        CTMUpgrade_v34_Test v34 = CTMUpgrade_v34_Test(address(ctmUpgrade));
        address ctm = ctmUpgrade.getCTMAddress();

        // Protocol version bumps, on the CTM and on the chain that crossed via the legacy leg.
        assertEq(IChainTypeManager(ctm).protocolVersion(), _expectedNewVersion, "CTM protocolVersion not bumped");
        assertEq(IGetters(_eraDiamond).getProtocolVersion(), _expectedNewVersion, "Era chain not upgraded");

        // The edge is one-shot and spent.
        assertTrue(v34.bootstrapMigration().executed(), "migration must be spent");

        // The WHOLE CTM domain landed under the bound executor: CTM ownership (the accept runs
        // inside `migrate()` itself) and the CTM-domain ProxyAdmin.
        address executor = address(v34.ctmUpgradeExecutor());
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

        // The cut the prepare ships is the object's composition, and this asserts the BYTES rather
        // than re-running the composer: the committed hash comes from the CTM's own storage, and
        // the payload is read back field by field against values derived here — the pinned engine
        // as the init target, no facet cuts, the release's verifier, the version edge, and (this
        // fixture is L1-only) the all-zero L2 transaction that makes the engine skip the L2 leg.
        address release = IChainTypeManager(ctm).currentRelease();
        bytes memory shippedCut = ctmUpgrade.getChainUpgradeDiamondCutData();
        assertEq(keccak256(shippedCut), _expectedUpgradeCutHash, "the shipped cut must be the committed one");
        Diamond.DiamondCutData memory cut = abi.decode(shippedCut, (Diamond.DiamondCutData));
        assertEq(cut.facetCuts.length, 0, "the bootstrap cut carries no facet cuts");
        assertEq(
            cut.initAddress,
            v34.getAddresses().stateTransition.defaultUpgrade,
            "the init target is the pinned engine"
        );
        ProposedUpgrade memory proposal = this.decodeUpgradeInit(cut.initCalldata);
        assertEq(proposal.newProtocolVersion, _expectedNewVersion, "the proposal carries the version edge");
        assertEq(proposal.verifier, ICTMRelease(release).verifier(), "the verifier comes off the pinned release");
        assertEq(proposal.upgradeTimestamp, 0, "the bootstrap manifest schedules no timestamp");
        assertEq(proposal.bootloaderHash, bytes32(0), "ZKsync OS has no bootloader bytecode");
        assertEq(proposal.defaultAccountHash, bytes32(0), "ZKsync OS has no default-account bytecode");
        assertEq(proposal.evmEmulatorHash, bytes32(0), "ZKsync OS has no EVM-emulator bytecode");
        assertEq(proposal.postUpgradeCalldata.length, 0, "no post-upgrade calldata rides the cut");
        assertEq(proposal.l1ContractsUpgradeCalldata.length, 0, "no L1 calldata rides the cut");
        assertEq(
            keccak256(abi.encode(proposal.l2ProtocolUpgradeTx)),
            keccak256(abi.encode(ProposedUpgradeLib.emptyL2CanonicalTransaction())),
            "an L1-only edge composes the all-zero L2 transaction"
        );

        // The genesis release is pinned as `currentRelease` (re-pointed to the release this
        // prepare run deployed) with the codehash anchor intact.
        assertEq(release, v34.getAddresses().stateTransition.currentRelease, "release must be the pipeline's");
        assertEq(IChainTypeManager(ctm).releaseCodehash(), release.codehash, "anchor must cover the pinned release");

        // New chain created AFTER the edge geneses from the pinned release at the new version.
        assertTrue(_newChainDiamond != address(0), "new chain not registered");
        assertEq(IGetters(_newChainDiamond).getProtocolVersion(), _expectedNewVersion, "new chain wrong version");

        // The bootstrap's CTM stage 2, every call a declared external action: the migration's own
        // post-state gate, the one bootstrap-JOIN authorization the recurring stage lifecycle
        // needs and the executor cannot grant itself (CTM-executor authorization on the ecosystem
        // executor — the migration pause needs no registration, being derived from the CTM
        // ownership `migrate()` just handed over), and the unpaused read. The harness already executed the prepared stage-2 bundle green in
        // `internalTest`; assert the emitted call list shape, that the gate still holds against
        // the final state, and that both joins landed.
        address bridgehub = coreUpgrade.getDiscoveredBridgehub().proxies.bridgehub;
        address chainAssetHandler = IBridgehubBase(bridgehub).chainAssetHandler();
        EcosystemUpgradeExecutor ecosystemExecutor = v34.ecosystemUpgradeExecutor();
        Call[] memory stage2 = v34.prepareStage2GovernanceCalls();
        assertEq(stage2.length, 3, "v34 CTM stage 2: post-state gate, the join authorization, unpaused read");
        assertEq(
            stage2[2].data,
            abi.encodeCall(UpgradeStageValidator.checkMigrationsUnpaused, ()),
            "stage 2 must end with the unpaused read"
        );
        assertEq(
            v34.externalActionDescriptions().length,
            8,
            "the bootstrap's CTM prepare declares every one of its governance and admin calls"
        );
        assertEq(stage2[0].target, address(v34.bootstrapMigration()), "stage 2 must target the migration");
        assertEq(
            stage2[0].data,
            abi.encodeCall(v34.bootstrapMigration().validateApplied, ()),
            "stage 2 must call validateApplied"
        );
        assertEq(stage2[1].target, address(ecosystemExecutor), "stage 2 must target the ecosystem executor");
        assertEq(
            stage2[1].data,
            abi.encodeCall(EcosystemUpgradeExecutor.setCTMExecutorAuthorization, (executor, true)),
            "stage 2 must authorize the executor on the ecosystem executor"
        );
        v34.bootstrapMigration().validateApplied();
        assertTrue(
            ecosystemExecutor.isAuthorizedCTMExecutor(executor),
            "the executor must be authorized on the ecosystem executor after stage 2"
        );
        // No pauser registration to assert: the ChainAssetHandler derives the authority from CTM
        // ownership, which `migrate()` already handed to the executor. What the join must leave is
        // an UNPAUSED CTM — nothing pauses until a transition's stage 0.
        assertEq(
            IOwnable(ctm).owner(),
            executor,
            "the executor owns the CTM, which is what lets it pause that CTM's migrations"
        );
        assertFalse(IChainAssetHandlerBase(chainAssetHandler).migrationPausedFor(ctm), "no pause before stage 0");
    }

    /// @dev Decodes an `upgrade(ProposedUpgrade)` init payload; external so the selector can be
    ///      sliced off calldata.
    function decodeUpgradeInit(bytes calldata _initCalldata) external pure returns (ProposedUpgrade memory) {
        require(bytes4(_initCalldata[:4]) == IDefaultUpgrade.upgrade.selector, "unexpected init selector");
        return abi.decode(_initCalldata[4:], (ProposedUpgrade));
    }
}
