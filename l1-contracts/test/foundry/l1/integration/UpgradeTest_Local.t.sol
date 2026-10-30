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
import {UpgradeIntegrationTestBase} from "./UpgradeTestShared.t.sol";
import {LiveL2Table} from "./UpgradeTestFresh_Local.t.sol";
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
import {Utils as DeployScriptUtils} from "../../../../deploy-scripts/utils/Utils.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {ICTMUpgradeExecutor} from "contracts/upgrades/registry/executors/ICTMUpgradeExecutor.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {IProxyUpgradeTransition} from "contracts/upgrades/registry/objects/IProxyUpgradeTransition.sol";
import {ChainRouting} from "test-utils/ChainRouting.sol";
import {IL1GenesisUpgrade} from "contracts/upgrades/IL1GenesisUpgrade.sol";
import {GenesisFacet, ProxyUpgradeRow} from "contracts/upgrades/registry/RegistryTypes.sol";
import {ContractsBytecodesLib} from "../../../../deploy-scripts/utils/bytecode/ContractsBytecodesLib.sol";

/// @notice The release's CTM upgrade over the previous release's L2 table, read off the live release: this fixture
///         is L1-only, and rebuilding the table from every L2 artifact runs out of memory here.
contract CTMUpgradeForLocalTest is CTMUpgrade_v36 {
    function getL2BytecodeInfoTable() internal view override returns (bytes[] memory) {
        return LiveL2Table.table(newConfig.ctm);
    }

    function getL2SystemProxyBytecodeInfo() internal view override returns (bytes memory) {
        return LiveL2Table.shell(newConfig.ctm);
    }

    /// @dev No L2 leg is relayed here, so the edge is L1-only: the base's empty plan, under which the transition
    ///      composes the all-zero L2 transaction. The anvil upgrade test covers the real L2 side.
    function authorL2Side() internal override returns (AuthoredL2Side memory) {
        return DefaultCTMUpgrade.authorL2Side();
    }
}

/// @notice The release's core upgrade over the previous release's fixture, whose `L1ChainAssetHandler` and
///         `L1MessageRoot` proxies run harness variants: `L1ChainAssetHandlerDev` (installed by the anvil Gateway setup
///         to re-enable chain migrations) and `DummyL1MessageRoot` (deployed with `USE_DUMMY_MESSAGE_ROOT`, it skips
///         proof verification). No release build matches them, so the edge replaces them like declared changes. The
///         anvil upgrade test's `CoreUpgradeForTests_v36` does the same.
contract CoreUpgradeForLocalTest is CoreUpgrade_v36 {
    function changedEcosystemImplementations() internal view override returns (string[] memory names) {
        string[] memory declared = super.changedEcosystemImplementations();
        names = new string[](declared.length + 2);
        for (uint256 i = 0; i < declared.length; ++i) {
            names[i] = declared[i];
        }
        names[declared.length] = "L1ChainAssetHandler";
        names[declared.length + 1] = "L1MessageRoot";
    }
}

/// @notice Chain leg for a chain whose admin does not act: the CTM's owner, the executor governance drives through
///         `forward`, crosses it through the CTM's passthrough.
contract ChainUpgradeByCTMOwnerForLocalTest is DefaultChainUpgrade {
    function upgradeChain(Diamond.DiamondCutData memory) public override {
        ChainTypeManager ctm = ChainTypeManager(IZKChain(config.chainDiamondProxyAddress).getChainTypeManager());
        vm.prank(ctm.owner());
        ctm.upgradeChainFromVersion(config.chainChainId, config.oldProtocolVersion);
    }
}

/// @notice The current release's upgrade, prepared by the real pipeline over the previous release's frozen L1 state
///         (see {PreviousReleaseFixture}), executed as the bundle the protocol-ops merge derives, with an L1-settled
///         chain of that release crossing it.
/// @dev Abstract so the upgraded ecosystem can be reused: a RECURRING prepare runs against it (see
///      `UpgradeTestRecurring_Local.t.sol`). Heavy execution and event assertions run in `setUp -> internalTest()`
///      (RAM constraint).
abstract contract UpgradeIntegrationReleaseFixture is UpgradeIntegrationTestBase, PreviousReleaseFixture {
    /// @dev The release's own local upgrade input, which protocol-ops' default prepare reads: it names no
    ///      target version, so the edge goes to the genesis version. Moved by `yarn new-release`.
    string internal constant RELEASE_UPGRADE_INPUT = "/upgrade-envs/v0.36.0-v36/local.toml";

    /// @dev The previous release's L1-settled chain that crosses the edge.
    uint256 internal constant UPGRADED_CHAIN_ID = 10;

    PreviousRelease internal previousRelease;

    /// @dev The release the previous release's CTM ran before the edge.
    address internal releaseBeforeUpgrade;

    /// @dev The upgraded chain's RollupDAManager before the edge, which the prepare builds the new
    ///      AdminFacet over.
    address internal rollupDAManagerBeforeUpgrade;

    function createCoreUpgrade() internal override returns (DefaultCoreUpgrade) {
        return new CoreUpgradeForLocalTest();
    }

    function createCTMUpgrade() internal override returns (DefaultCTMUpgrade) {
        return new CTMUpgradeForLocalTest();
    }

    function createChainUpgrade() internal virtual override returns (DefaultChainUpgrade) {
        return new DefaultChainUpgrade();
    }

    /// @dev The env input carries the live checker forward from the previous prepare's output.
    function afterInitHook() internal override {
        ctmUpgrade.setEIP7702Checker(previousRelease.eip7702Checker);
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
                zkTokenAssetId: previousRelease.zkTokenAssetId
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
        releaseBeforeUpgrade = IChainTypeManager(previousRelease.chainTypeManager).currentRelease();
        rollupDAManagerBeforeUpgrade = IAdmin(chain.diamondProxy).getRollupDAManager();

        ECOSYSTEM_UPGRADE_INPUT = RELEASE_UPGRADE_INPUT;
        ECOSYSTEM_OUTPUT = "/script-out/foundry-upgrade/local-release-core-out.toml";
        CTM_OUTPUT = "/script-out/foundry-upgrade/local-release-ctm.toml";
        CORE_OUTPUT = "/script-out/foundry-upgrade/local-release-core.toml";
        setupUpgrade();

        address bridgehub = coreUpgrade.getDiscoveredBridgehub().proxies.bridgehub;
        bytes32 baseTokenAssetId = IBridgehubBase(bridgehub).baseTokenAssetId(chainId);
        _expectedBaseTokenAssetId = baseTokenAssetId;
        vm.mockCall(bridgehub, abi.encodeCall(IBridgehubBase.baseTokenAssetId, 0), abi.encode(baseTokenAssetId));

        internalTest();
    }
}

/// @notice The release edge's own assertions over the fixture above. They follow what the version scripts declare
///         rather than naming the contracts this release changes.
contract UpgradeIntegrationTestLocal is UpgradeIntegrationReleaseFixture {
    using stdToml for string;

    /// @notice The edge's objects re-derive from the build artifact's creation code, the salt each leg's output records
    ///         and the manifest each object serves, as `protocol-ops ecosystem verify-package` re-derives them.
    function test_edgeObjectsAreReproducibleFromTheirReviewedArguments() public view {
        string memory root = vm.projectRoot();
        string memory coreOutput = vm.readFile(string.concat(root, CORE_OUTPUT));
        string memory ctmOutput = vm.readFile(string.concat(root, CTM_OUTPUT));
        (, bytes32 coreSalt) = coreUpgrade.getCreate2FactoryParams();
        (, bytes32 ctmSalt) = ctmUpgrade.getCreate2FactoryParams();
        assertEq(coreOutput.readBytes32("$.create2_factory_salt"), coreSalt, "the core leg's salt");
        assertEq(ctmOutput.readBytes32("$.create2_factory_salt"), ctmSalt, "the CTM leg's salt");

        ICTMTransition transition = ICTMTransition(ctmOutput.readAddress("$.registry.ctm_transition_addr"));
        assertEq(ctmOutput.readAddress("$.registry.ctm_release_addr"), transition.newRelease(), "the pinned release");
        assertEq(
            ctmOutput.readAddress("$.registry.ctm_upgrade_executor_addr"),
            IOwnable(ctmUpgrade.getCTMAddress()).owner(),
            "the executor the merge derives the commit on"
        );
        assertEq(
            DeployScriptUtils.canonicalCreate2Address(
                ctmSalt,
                vm.getCode("CTMTransition.sol:CTMTransition"),
                abi.encode(transition.getManifest())
            ),
            address(transition),
            "the transition re-derives from the manifest it serves"
        );

        address coreTransition = coreOutput.readAddress("$.registry.core_transition_addr");
        assertEq(coreTransition, address(coreUpgrade.coreTransition()), "the output names the core transition");
        if (coreTransition != address(0)) {
            assertEq(
                DeployScriptUtils.canonicalCreate2Address(
                    coreSalt,
                    vm.getCode("ProxyUpgradeTransition.sol:ProxyUpgradeTransition"),
                    abi.encode(IProxyUpgradeTransition(coreTransition).getManifest())
                ),
                coreTransition,
                "the core transition re-derives from the manifest it serves"
            );
        }
    }

    /// @notice Every member the edge deploys carries a `[member_deployments]` record in the output of the leg that
    ///         deployed it, and re-derives from it, as `protocol-ops ecosystem verify-package` checks
    ///         (`member_construction`). A member the edge reuses is the departing release's and has no record.
    function test_edgeMembersAreReproducibleFromTheirRecords() public view {
        string memory root = vm.projectRoot();
        string memory coreOutput = vm.readFile(string.concat(root, CORE_OUTPUT));
        string memory ctmOutput = vm.readFile(string.concat(root, CTM_OUTPUT));
        (, bytes32 coreSalt) = coreUpgrade.getCreate2FactoryParams();
        (, bytes32 ctmSalt) = ctmUpgrade.getCreate2FactoryParams();
        ICTMTransition transition = ICTMTransition(ctmOutput.readAddress("$.registry.ctm_transition_addr"));
        ICTMRelease newRelease = ICTMRelease(transition.newRelease());
        ICTMRelease oldRelease = ICTMRelease(transition.fromRelease());

        GenesisFacet[] memory facets = newRelease.genesisFacets();
        GenesisFacet[] memory oldFacets = oldRelease.genesisFacets();
        for (uint256 i = 0; i < facets.length; ++i) {
            if (i < oldFacets.length && facets[i].facet == oldFacets[i].facet) {
                continue;
            }
            (string memory name, bytes memory args) = _recordedMember(ctmOutput, ctmSalt, facets[i].facet);
            // The two immutables code identity cannot see, held at their source.
            if (keccak256(bytes(name)) == keccak256("AdminFacet")) {
                (uint256 l1ChainId, address rollupDAManager) = abi.decode(args, (uint256, address));
                assertEq(l1ChainId, block.chainid, "AdminFacet is built for this L1");
                assertEq(rollupDAManager, rollupDAManagerBeforeUpgrade, "AdminFacet is built over the live manager");
            } else if (keccak256(bytes(name)) == keccak256("MailboxFacet")) {
                (, , address eip7702Checker, bool isTestnet) = abi.decode(args, (uint256, address, address, bool));
                assertEq(eip7702Checker, previousRelease.eip7702Checker, "MailboxFacet keeps the live checker");
                assertTrue(isTestnet, "MailboxFacet is built for the env's testnet verifier");
            }
        }
        if (newRelease.diamondInit() != oldRelease.diamondInit()) {
            _recordedMember(ctmOutput, ctmSalt, newRelease.diamondInit());
        }
        (address newGenesisEngine, , ) = newRelease.genesisParams();
        (address oldGenesisEngine, , ) = oldRelease.genesisParams();
        if (newGenesisEngine != oldGenesisEngine) {
            _recordedMember(ctmOutput, ctmSalt, newGenesisEngine);
        }
        _recordedMember(ctmOutput, ctmSalt, transition.upgradeEngine());

        if (address(coreUpgrade.coreTransition()) != address(0)) {
            ProxyUpgradeRow[] memory rows = coreUpgrade.coreTransition().rows();
            for (uint256 i = 0; i < rows.length; ++i) {
                _recordedMember(coreOutput, coreSalt, rows[i].implNew);
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

    function test_releaseEdge_Local() public view {
        address ctm = ctmUpgrade.getCTMAddress();
        address release = IChainTypeManager(ctm).currentRelease();
        ICTMTransition transition = ICTMTransition(
            IChainTypeManager(ctm).upgradeTransition(ctmUpgrade.getOldProtocolVersion())
        );

        // The version moves on the CTM and on the chain that crossed.
        assertEq(IChainTypeManager(ctm).protocolVersion(), _expectedNewVersion, "CTM protocolVersion not bumped");
        assertEq(
            IGetters(_upgradedChainDiamond).getProtocolVersion(),
            _expectedNewVersion,
            "the chain did not cross the edge"
        );

        // The CTM committed the prepare's transition, from the previous release's release to the one it pins.
        assertTrue(address(transition) != address(0), "no transition committed for the departing version");
        assertEq(transition.fromRelease(), releaseBeforeUpgrade, "the edge departs from the previous release");
        assertEq(transition.newRelease(), release, "the CTM serves the release the transition pins");
        assertEq(release, ctmUpgrade.getAddresses().stateTransition.currentRelease, "release must be the pipeline's");
        assertEq(transition.upgradeEngine(), ctmUpgrade.committedUpgradeEngine(), "the engine the prepare reports");

        // Authority stays in the registry model: governance owns the executor, which stays bound to the CTM.
        address executor = IOwnable(ctm).owner();
        assertEq(address(ICTMUpgradeExecutor(executor).CHAIN_TYPE_MANAGER()), ctm, "the CTM left its executor");
        assertEq(IOwnable(executor).owner(), previousRelease.governance, "governance owns the CTM executor");
        assertFalse(
            IChainAssetHandlerBase(IBridgehubBase(previousRelease.bridgehub).chainAssetHandler()).migrationPausedFor(
                ctm
            ),
            "the upgrade takes no migration pause"
        );

        // The crossed chain runs exactly the release, and this L1-only edge leaves no L2 upgrade pending.
        assertEq(
            address(IGetters(_upgradedChainDiamond).getVerifier()),
            ICTMRelease(release).verifier(),
            "the chain runs the pinned release's verifier"
        );
        assertTrue(
            ChainRouting.matchesRelease(ICTMRelease(release), _upgradedChainDiamond),
            "the engine installed exactly the release's routing"
        );
        assertEq(
            IGetters(_upgradedChainDiamond).getL2SystemContractsUpgradeTxHash(),
            bytes32(0),
            "no L2 protocol upgrade transaction on an L1-only edge"
        );
        assertEq(
            IAdmin(_upgradedChainDiamond).getRollupDAManager(),
            rollupDAManagerBeforeUpgrade,
            "the chain keeps its RollupDAManager across the edge"
        );

        // Every ecosystem implementation the core leg replaces is installed.
        if (address(coreUpgrade.coreTransition()) != address(0)) {
            ProxyUpgradeRow[] memory rows = coreUpgrade.coreTransition().rows();
            for (uint256 i = 0; i < rows.length; ++i) {
                assertEq(DeployScriptUtils.getImplementation(rows[i].proxy), rows[i].implNew, "row not installed");
            }
        }

        // The CTM serves the release's genesis engine, and a chain created after the edge geneses from the pinned
        // release at the new version: its pending L2 transaction is the one the release's engine composes for it.
        (address releaseGenesisEngine, , ) = ICTMRelease(release).genesisParams();
        assertEq(
            IChainTypeManager(ctm).l1GenesisUpgrade(),
            releaseGenesisEngine,
            "the CTM serves the release's engine"
        );
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
    }
}

/// @notice The release edge over the same fixture, with the chain crossed by the CTM's owner instead of its admin
///         (see {ChainUpgradeByCTMOwnerForLocalTest}).
contract UpgradeIntegrationTestLocalCTMOwnerCrossing is UpgradeIntegrationReleaseFixture {
    function createChainUpgrade() internal override returns (DefaultChainUpgrade) {
        return new ChainUpgradeByCTMOwnerForLocalTest();
    }

    function test_theCTMOwnerCrossesAChainOverTheReleaseEdge() public view {
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
            "the engine installed exactly the release's routing"
        );
    }
}
