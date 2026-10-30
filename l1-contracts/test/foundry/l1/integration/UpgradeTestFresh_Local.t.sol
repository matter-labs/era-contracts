// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// solhint-disable gas-custom-errors

import {stdToml} from "forge-std/StdToml.sol";

import {DefaultCoreUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCoreUpgrade.s.sol";
import {DefaultCTMUpgrade} from "deploy-scripts/upgrade/default-upgrade/DefaultCTMUpgrade.s.sol";
import {DefaultTransitionReplacement} from "deploy-scripts/upgrade/default-upgrade/DefaultTransitionReplacement.s.sol";

import {Call} from "contracts/governance/Common.sol";
import {IUpgradeExecutorBase} from "contracts/governance/IUpgradeExecutorBase.sol";
import {IOwnable} from "contracts/common/interfaces/IOwnable.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {ICTMUpgradeExecutor} from "contracts/upgrades/registry/executors/ICTMUpgradeExecutor.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {TransitionNotCommitted} from "contracts/common/L1ContractErrors.sol";

import {ZKChainDeployer} from "./_SharedZKChainDeployer.t.sol";

/// @dev A fresh ecosystem's live release was pinned with the real L2 table; a hop re-pinning the same
///      table reads it off that release rather than rebuilding it from every L2 artifact (MemoryOOG in
///      this harness), so an unchanged table stays unchanged.
library LiveL2Table {
    function table(address _ctm) internal view returns (bytes[] memory) {
        return ICTMRelease(IChainTypeManager(_ctm).currentRelease()).l2BytecodeInfos();
    }

    function shell(address _ctm) internal view returns (bytes memory) {
        return ICTMRelease(IChainTypeManager(_ctm).currentRelease()).l2SystemProxyBytecodeInfo();
    }
}

/// @notice The chain-release hop of these tests: a fresh verifier pinned by a new release over the
///         live table, carried across the version edge by a transition.
contract FreshVerifierReleaseHop is DefaultCTMUpgrade {
    function getL2BytecodeInfoTable() internal view override returns (bytes[] memory) {
        return LiveL2Table.table(newConfig.ctm);
    }

    function getL2SystemProxyBytecodeInfo() internal view override returns (bytes memory) {
        return LiveL2Table.shell(newConfig.ctm);
    }

    function deployNewCTMContracts() public override {
        super.deployNewCTMContracts();
        deployVerifiers();
    }

    /// @notice The transition this prepare deployed.
    function preparedTransition() external view returns (address) {
        return upgradeAddresses.ctmTransition;
    }

    /// @notice The CTM-domain infrastructure transition this prepare deployed (zero when none).
    function preparedInfrastructure() external view returns (address) {
        return upgradeAddresses.ctmInfrastructureTransition;
    }
}

/// @notice The replacement prepare over the live table (see {LiveL2Table}).
contract FreshTransitionReplacement is DefaultTransitionReplacement {
    function getL2BytecodeInfoTable() internal view override returns (bytes[] memory) {
        return LiveL2Table.table(newConfig.ctm);
    }

    function getL2SystemProxyBytecodeInfo() internal view override returns (bytes memory) {
        return LiveL2Table.shell(newConfig.ctm);
    }

    /// @notice The replacement transition this prepare deployed.
    function preparedReplacement() external view returns (address) {
        return upgradeAddresses.ctmTransition;
    }
}

/// @notice The ecosystem side of these hops: no ecosystem singleton changes.
contract CoreUpgradeNoLegForFresh is DefaultCoreUpgrade {}

/// @notice A FRESH ecosystem — `DeployL1CoreContracts` + `DeployCTM` + `RegisterCTM` + governance's accepts,
///         no bootstrap — is born in the registry model: it runs a registry-driven v36 -> v37 upgrade
///         directly through the executors the deployment created, and a committed transition of it can be
///         repaired through the replacement prepare (`DefaultTransitionReplacement`). See "Replacing a
///         committed transition" in {protocol-docs/ecosystem-upgrade-coordination.md}.
contract UpgradeIntegrationTestFreshEcosystemLocal is ZKChainDeployer {
    using stdToml for string;

    /// @dev Names v37 as the target: one minor past the fresh ecosystem's genesis version.
    string internal constant HOP_INPUT = "/upgrade-envs/foundry-upgrade.toml";
    bytes32 internal constant HOP_SALT = keccak256("fresh-ecosystem-hop");
    /// @dev A replacement prepared under its own salt deploys its own engine, which is what makes it a
    ///      different edge from the one it replaces.
    bytes32 internal constant REPLACEMENT_SALT = keccak256("fresh-ecosystem-replacement");
    /// @dev The deadline the deadline-moving replacement sets.
    uint256 internal constant REPLACEMENT_DEADLINE = 4_000_000_000;

    address internal ctm;
    address internal governance;
    address internal eraChainAdmin;

    function setUp() public {
        vm.createDir(string.concat(vm.projectRoot(), "/script-out/foundry-upgrade"), true);
        _deployL1Contracts();
        _deployEra();
        acceptPendingAdmin();
        ctm = address(addresses.chainTypeManager);
        governance = IOwnable(upgradeExecutors.ctmExecutor).owner();
        eraChainAdmin = IZKChain(getZKChainAddress(eraZKChainId)).getAdmin();
    }

    /// @notice No bootstrap ran, and none is needed: the hop's prepare finds the executors the deployment
    ///         created, governance applies the transition through the CTM executor, the CTM commits the
    ///         edge and a chain crosses it through the CTM executor.
    function test_freshEcosystem_runsARegistryDrivenHopWithoutABootstrap() public {
        uint256 genesisVersion = IChainTypeManager(ctm).protocolVersion();
        address genesisRelease = IChainTypeManager(ctm).currentRelease();
        assertEq(IOwnable(ctm).owner(), upgradeExecutors.ctmExecutor, "born owned by the CTM executor");
        assertEq(
            IChainTypeManager(ctm).upgradeCutHash(genesisVersion),
            bytes32(0),
            "no legacy (bootstrap) edge was ever committed"
        );

        FreshVerifierReleaseHop hop = _prepareHop();
        assertEq(
            hop.boundCTMUpgradeExecutor(),
            upgradeExecutors.ctmExecutor,
            "the prepare finds the born CTM executor"
        );
        assertEq(hop.preparedInfrastructure(), address(0), "a verifier release swaps no CTM-domain implementation");
        assertEq(hop.bootstrapMigrationAddress(), address(0), "a recurring prepare deploys no migration");

        ICTMTransition transition = ICTMTransition(hop.preparedTransition());
        assertEq(transition.fromRelease(), genesisRelease, "the edge departs from the genesis release");
        assertEq(transition.oldProtocolVersion(), genesisVersion);
        _applyTransition(transition);

        uint256 newVersion = transition.newProtocolVersion();
        assertTrue(newVersion > genesisVersion, "a version edge");
        assertEq(IChainTypeManager(ctm).protocolVersion(), newVersion, "the CTM committed the edge");
        assertEq(IChainTypeManager(ctm).currentRelease(), transition.newRelease(), "and installed the release");
        assertEq(IChainTypeManager(ctm).upgradeTransition(genesisVersion), address(transition));

        address era = getZKChainAddress(eraZKChainId);
        vm.prank(eraChainAdmin);
        CTMUpgradeExecutor(payable(upgradeExecutors.ctmExecutor)).upgradeChain(transition, eraZKChainId);
        assertEq(IGetters(era).getProtocolVersion(), newVersion, "the chain crossed the edge");
        assertEq(
            address(IGetters(era).getVerifier()),
            ICTMRelease(transition.newRelease()).verifier(),
            "and runs the new release's verifier"
        );
    }

    /// @notice The replacement prepare deploys a replacement for the committed v36 -> v37 transition and
    ///         emits ONE governance call; executed, it repairs the departure for a chain that has not crossed
    ///         it yet — the replaced object stops working at once and the chain crosses with the replacement.
    function test_replacementPrepare_repairsTheCommittedTransitionForALaggingChain() public {
        ICTMTransition replaced = ICTMTransition(_prepareHopAndRun().preparedTransition());
        uint256 departing = replaced.oldProtocolVersion();
        uint256 deadlineBefore = IChainTypeManager(ctm).protocolVersionDeadline(departing);

        FreshTransitionReplacement replacement = _initReplacement(REPLACEMENT_SALT, "fresh-replacement");
        replacement.setReplacedTransition(address(replaced));
        replacement.prepareCTMUpgrade();
        replacement.prepareDefaultCTMAdminCalls();
        Call[] memory bundle = replacement.prepareDefaultGovernanceCalls();

        // ── The replacement departs exactly where the replaced edge does, onto the release a chain continues from ──
        ICTMTransition repaired = ICTMTransition(replacement.preparedReplacement());
        assertTrue(address(repaired) != address(replaced), "a new object");
        assertEq(repaired.fromRelease(), replaced.fromRelease(), "the same source release");
        assertEq(repaired.oldProtocolVersionDeadline(), replaced.oldProtocolVersionDeadline(), "the same deadline");
        assertEq(repaired.newRelease(), IChainTypeManager(ctm).currentRelease(), "the continuation release");
        assertEq(repaired.newProtocolVersion(), replaced.newProtocolVersion(), "the same target");
        assertTrue(repaired.upgradeEngine() != replaced.upgradeEngine(), "this run's engine is the repair");

        // ── One call, and nothing else ──
        assertEq(bundle.length, 1, "the single forward");
        Call[] memory inner = new Call[](1);
        inner[0] = Call({
            target: ctm,
            value: 0,
            data: abi.encodeCall(IChainTypeManager.replaceUpgradeTransition, (replaced, repaired))
        });
        assertEq(bundle[0].target, upgradeExecutors.ctmExecutor, "sent to the CTM executor");
        assertEq(bundle[0].data, abi.encodeCall(IUpgradeExecutorBase.forward, (inner)), "forwarding the replacement");
        assertEq(replacement.externalActionEntries().length, 1, "declared as the prepare's one external action");

        string memory output = vm.readFile(
            string.concat(vm.projectRoot(), "/script-out/foundry-upgrade/fresh-replacement-ctm.toml")
        );
        assertEq(output.readAddress("$.registry.replaced_transition_addr"), address(replaced));
        assertEq(output.readAddress("$.registry.replacement_transition_addr"), address(repaired));
        assertEq(output.readAddress("$.registry.ctm_transition_addr"), address(repaired));
        assertEq(
            output.readAddress("$.registry.ctm_infrastructure_transition_addr"),
            address(0),
            "no infrastructure transition"
        );
        assertEq(output.readUint("$.contracts_config.old_protocol_version"), departing);

        // ── Governance executes it ──
        vm.expectEmit(true, true, true, true, ctm);
        emit IChainTypeManager.UpgradeTransitionReplaced(departing, address(replaced), address(repaired));
        _executeAsGovernance(bundle[0]);
        assertEq(IChainTypeManager(ctm).upgradeTransition(departing), address(repaired), "the departure is repaired");
        assertEq(
            IChainTypeManager(ctm).protocolVersionDeadline(departing),
            deadlineBefore,
            "no deadline was asked to move"
        );

        // ── The lagging chain crosses with the replacement; the replaced object stops working ──
        CTMUpgradeExecutor ctmExecutor = CTMUpgradeExecutor(payable(upgradeExecutors.ctmExecutor));
        vm.prank(eraChainAdmin);
        vm.expectRevert(abi.encodeWithSelector(TransitionNotCommitted.selector, address(replaced), address(repaired)));
        ctmExecutor.upgradeChain(replaced, eraZKChainId);
        vm.prank(eraChainAdmin);
        ctmExecutor.upgradeChain(repaired, eraZKChainId);
        assertEq(
            IGetters(getZKChainAddress(eraZKChainId)).getProtocolVersion(),
            repaired.newProtocolVersion(),
            "the chain crossed with the replacement"
        );
    }

    /// @notice A deadline move rides the same `forward`, after the replacement.
    function test_replacementPrepare_movesTheDeadlineInTheSameForward() public {
        ICTMTransition replaced = ICTMTransition(_prepareHopAndRun().preparedTransition());
        uint256 departing = replaced.oldProtocolVersion();

        FreshTransitionReplacement replacement = _initReplacement(REPLACEMENT_SALT, "fresh-replacement-deadline");
        replacement.setReplacedTransition(address(replaced));
        replacement.setReplacementDeadline(REPLACEMENT_DEADLINE);
        replacement.prepareCTMUpgrade();
        Call[] memory bundle = replacement.prepareDefaultGovernanceCalls();

        Call[] memory inner = new Call[](2);
        inner[0] = Call({
            target: ctm,
            value: 0,
            data: abi.encodeCall(
                IChainTypeManager.replaceUpgradeTransition,
                (replaced, ICTMTransition(replacement.preparedReplacement()))
            )
        });
        inner[1] = Call({
            target: ctm,
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setProtocolVersionDeadline, (departing, REPLACEMENT_DEADLINE))
        });
        assertEq(bundle.length, 1);
        assertEq(bundle[0].data, abi.encodeCall(IUpgradeExecutorBase.forward, (inner)), "both calls in one forward");

        _executeAsGovernance(bundle[0]);
        assertEq(IChainTypeManager(ctm).upgradeTransition(departing), replacement.preparedReplacement());
        assertEq(IChainTypeManager(ctm).protocolVersionDeadline(departing), REPLACEMENT_DEADLINE, "deadline moved");
    }

    /// @notice A stale proposal — naming a transition that is no longer the committed one — is refused at
    ///         preparation, not first by the CTM's compare-and-replace at execution.
    function test_replacementPrepare_refusesAStaleReplacedTransition() public {
        ICTMTransition replaced = ICTMTransition(_prepareHopAndRun().preparedTransition());
        FreshTransitionReplacement first = _initReplacement(REPLACEMENT_SALT, "fresh-replacement-first");
        first.setReplacedTransition(address(replaced));
        first.prepareCTMUpgrade();
        Call[] memory bundle = first.prepareDefaultGovernanceCalls();
        _executeAsGovernance(bundle[0]);

        FreshTransitionReplacement stale = _initReplacement(keccak256("stale"), "fresh-replacement-stale");
        stale.setReplacedTransition(address(replaced));
        vm.expectRevert("the replaced transition is not the one committed for its departure");
        stale.prepareCTMUpgrade();
    }

    /// @notice A replacement pinning exactly the replaced edge repairs nothing: refused at preparation. Under
    ///         the hop's own salt the engine lands on the same address, and nothing else differs.
    function test_replacementPrepare_refusesAReplacementThatChangesNothing() public {
        ICTMTransition replaced = ICTMTransition(_prepareHopAndRun().preparedTransition());
        FreshTransitionReplacement replacement = _initReplacement(HOP_SALT, "fresh-replacement-noop");
        replacement.setReplacedTransition(address(replaced));
        vm.expectRevert("the replacement pins exactly the edge it replaces");
        replacement.prepareCTMUpgrade();
    }

    // ───────────────────────────── helpers ─────────────────────────────

    function _prepareHop() internal returns (FreshVerifierReleaseHop hop) {
        CoreUpgradeNoLegForFresh core = new CoreUpgradeNoLegForFresh();
        core.initializeWithArgs(
            address(addresses.bridgehub),
            HOP_SALT,
            HOP_INPUT,
            "/script-out/foundry-upgrade/fresh-hop-core.toml"
        );
        hop = new FreshVerifierReleaseHop();
        _initCTMPrepare(hop, HOP_SALT, "/script-out/foundry-upgrade/fresh-hop-ctm.toml");
        core.prepareEcosystemUpgrade();
        assertEq(address(core.coreTransition()), address(0), "no ecosystem leg");
        assertEq(address(core.getCoreUpgradeExecutor()), upgradeExecutors.coreExecutor, "the born core executor");
        hop.setCoreTransition(address(core.coreTransition()));
        hop.prepareCTMUpgrade();
    }

    /// @dev A hop committed and completed on L1; every chain stays at the departing version.
    function _prepareHopAndRun() internal returns (FreshVerifierReleaseHop hop) {
        hop = _prepareHop();
        _applyTransition(ICTMTransition(hop.preparedTransition()));
    }

    function _initReplacement(
        bytes32 _salt,
        string memory _outName
    ) internal returns (FreshTransitionReplacement replacement) {
        replacement = new FreshTransitionReplacement();
        _initCTMPrepare(replacement, _salt, string.concat("/script-out/foundry-upgrade/", _outName, "-ctm.toml"));
    }

    /// @dev What protocol-ops passes a CTM prepare, from the fresh deployment.
    function _initCTMPrepare(DefaultCTMUpgrade _prepare, bytes32 _salt, string memory _output) internal {
        // solhint-disable-next-line func-named-parameters
        _prepare.initializeWithArgs(
            ctm,
            ctmAddresses.daAddresses.daContracts.rollupDAManager,
            _salt,
            HOP_INPUT,
            _output,
            governance,
            ecosystemConfig.zkTokenAssetId,
            true
        );
        _prepare.setEIP7702Checker(ctmAddresses.admin.eip7702Checker);
    }

    /// @dev The one governance call of a transition-only registry-driven upgrade.
    function _applyTransition(ICTMTransition _transition) internal {
        CTMUpgradeExecutor ctmExecutor = CTMUpgradeExecutor(payable(upgradeExecutors.ctmExecutor));
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ICTMUpgradeExecutor.CTMUpgradeApplied(
            address(_transition),
            _transition.oldProtocolVersion(),
            _transition.newProtocolVersion()
        );
        vm.prank(governance);
        ctmExecutor.applyCTMUpgrade(_transition);
    }

    function _executeAsGovernance(Call memory _call) internal {
        vm.prank(governance);
        (bool success, bytes memory returnData) = _call.target.call{value: _call.value}(_call.data);
        if (!success) {
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
    }
}
