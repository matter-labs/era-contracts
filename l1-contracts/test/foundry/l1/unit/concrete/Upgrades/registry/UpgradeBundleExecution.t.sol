// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {StorageSlot} from "@openzeppelin/contracts-v4/utils/StorageSlot.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {Call} from "contracts/governance/Common.sol";
import {Governance} from "contracts/governance/Governance.sol";
import {IGovernance} from "contracts/governance/IGovernance.sol";
import {IUpgradeExecutorBase} from "contracts/governance/IUpgradeExecutorBase.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ProxyUpgradeTransition} from "contracts/upgrades/registry/objects/ProxyUpgradeTransition.sol";
import {IProxyUpgradeTransition} from "contracts/upgrades/registry/objects/IProxyUpgradeTransition.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {ICTMUpgradeExecutor} from "contracts/upgrades/registry/executors/ICTMUpgradeExecutor.sol";
import {ICoreUpgradeExecutor} from "contracts/upgrades/registry/executors/ICoreUpgradeExecutor.sol";
import {ProxyUpgradeRowLib} from "contracts/upgrades/registry/libraries/ProxyUpgradeRowLib.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";
import {
    L2BytecodeNotPublished,
    ProxyUpgradeDomainMismatch,
    ProxyUpgradeRowMismatch,
    RegistryTargetHasNoCode,
    TransitionReleaseMismatch
} from "contracts/common/L1ContractErrors.sol";
import {ProxyUpgradeDomain, ProxyUpgradeRow} from "contracts/upgrades/registry/RegistryTypes.sol";

/// @dev Three distinct implementations so a proxy row is a real `expectedOldImpl -> implNew`
///      edge and a proxy can also sit at an implementation the row does not know.
contract ExecutionImplOld {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract ExecutionImplNew {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract ExecutionImplOther {
    function version() external pure returns (uint256) {
        return 3;
    }
}

/// @dev An implementation whose reinitializer re-points its own proxy elsewhere: a swap whose end
///      state is not the row's `implNew`. The write happens inside the upgrade call, through the
///      proxy's own delegatecall; the test itself touches no storage.
contract SelfRepointingImpl {
    bytes32 internal constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    address internal immutable REPOINT_TO;

    constructor(address _repointTo) {
        REPOINT_TO = _repointTo;
    }

    function initializeUpgrade() external {
        StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value = REPOINT_TO;
    }
}

/// @notice An upgrade as governance executes it: ONE `Governance` proposal whose calls are the
///         domain executors' entrypoints in canonical order — `applyL1Upgrade`,
///         `applyInfrastructureUpgrade`, `applyCTMUpgrade` — or any subsequence of them
///         ({protocol-docs/ecosystem-upgrade-coordination.md}). Covers the happy path and its events
///         and end state, each leg alone, all-or-nothing execution across legs (a failure in any
///         call reverts every earlier swap), domain separation of the proxy upgrade objects, stale
///         and undeployed objects, and that no migration pause is needed or touched.
/// @dev The executors are owned by a REAL `Governance` contract here (not the fixture's EOA): the
///      atomicity under test is the proposal's, and separate owner transactions would not show it.
///      The order of the calls is the proposal's to get right — the executors cannot see each
///      other — and is checked off-chain by protocol-ops' package verification.
contract UpgradeBundleExecutionTest is CTMUpgradeExecutorFixture {
    /// @dev `Governance` reads timestamp 1 (the test default) as "executed", so a zero-delay proposal
    ///      needs a later block.
    uint256 internal constant GOVERNANCE_READY_TIMESTAMP = 100;

    Governance internal governance;
    address internal governanceAdmin;
    uint256 internal proposalSalt;

    address internal implOld;
    address internal implNew;
    address internal implOther;
    TransparentUpgradeableProxy internal ctmDomainProxy;
    TransparentUpgradeableProxy internal ecosystemProxy;
    ProxyUpgradeTransition internal coreTransition;
    ProxyUpgradeTransition internal infrastructure;

    function setUp() public override {
        super.setUp();
        implOld = address(new ExecutionImplOld());
        implNew = address(new ExecutionImplNew());
        implOther = address(new ExecutionImplOther());
        // One proxy per authority domain, each under the ProxyAdmin its executor owns.
        ctmDomainProxy = new TransparentUpgradeableProxy(implOld, address(ctmProxyAdmin), hex"");
        ecosystemProxy = new TransparentUpgradeableProxy(implOld, address(ecosystemProxyAdmin), hex"");
        coreTransition = _deployCoreTransition(_row(address(ecosystemProxy), implOld, implNew));
        infrastructure = _deployCTMInfrastructureTransition(_row(address(ctmDomainProxy), implOld, implNew));

        // Both executors move under a real Governance, which accepts them in its first proposal.
        vm.warp(GOVERNANCE_READY_TIMESTAMP);
        governanceAdmin = makeAddr("governanceAdmin");
        governance = new Governance(governanceAdmin, address(0), 0);
        vm.startPrank(governor);
        coreExecutor.transferOwnership(address(governance));
        ctmExecutor.transferOwnership(address(governance));
        vm.stopPrank();
        Call[] memory accept = new Call[](2);
        accept[0] = Call({
            target: address(coreExecutor),
            value: 0,
            data: abi.encodeCall(Ownable2Step.acceptOwnership, ())
        });
        accept[1] = Call({
            target: address(ctmExecutor),
            value: 0,
            data: abi.encodeCall(Ownable2Step.acceptOwnership, ())
        });
        _executeProposal(_schedule(accept));
        assertEq(coreExecutor.owner(), address(governance), "fixture: governance owns the core executor");
        assertEq(ctmExecutor.owner(), address(governance), "fixture: governance owns the CTM executor");
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _coreLeg(address _coreTransition) internal view returns (Call memory) {
        return
            Call({
                target: address(coreExecutor),
                value: 0,
                data: abi.encodeCall(ICoreUpgradeExecutor.applyL1Upgrade, (IProxyUpgradeTransition(_coreTransition)))
            });
    }

    function _infrastructureLeg(address _infrastructure) internal view returns (Call memory) {
        return
            Call({
                target: address(ctmExecutor),
                value: 0,
                data: abi.encodeCall(
                    ICTMUpgradeExecutor.applyInfrastructureUpgrade,
                    (IProxyUpgradeTransition(_infrastructure))
                )
            });
    }

    function _transitionLeg(address _transition) internal view returns (Call memory) {
        return
            Call({
                target: address(ctmExecutor),
                value: 0,
                data: abi.encodeCall(ICTMUpgradeExecutor.applyCTMUpgrade, (ICTMTransition(_transition)))
            });
    }

    function _bundle(Call memory _a) internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = _a;
    }

    function _bundle(Call memory _a, Call memory _b) internal pure returns (Call[] memory calls) {
        calls = new Call[](2);
        calls[0] = _a;
        calls[1] = _b;
    }

    function _bundle(Call memory _a, Call memory _b, Call memory _c) internal pure returns (Call[] memory calls) {
        calls = new Call[](3);
        calls[0] = _a;
        calls[1] = _b;
        calls[2] = _c;
    }

    /// @dev The full canonical bundle: core -> CTM infrastructure -> CTM transition.
    function _fullBundle(address _transition) internal view returns (Call[] memory) {
        return
            _bundle(
                _coreLeg(address(coreTransition)),
                _infrastructureLeg(address(infrastructure)),
                _transitionLeg(_transition)
            );
    }

    /// @dev Schedules `_calls` as one transparent proposal ready immediately (min delay zero).
    function _schedule(Call[] memory _calls) internal returns (IGovernance.Operation memory operation) {
        operation = IGovernance.Operation({calls: _calls, predecessor: bytes32(0), salt: bytes32(++proposalSalt)});
        vm.prank(governanceAdmin);
        governance.scheduleTransparent(operation, 0);
    }

    function _executeProposal(IGovernance.Operation memory _operation) internal {
        vm.prank(governanceAdmin);
        governance.execute(_operation);
    }

    /// @dev Schedules and executes `_calls` expecting the whole proposal to revert with `_error`.
    ///      Returns the still-ready proposal, so a test can execute the very same one later.
    function _expectProposalRevert(
        Call[] memory _calls,
        bytes memory _error
    ) internal returns (IGovernance.Operation memory operation) {
        operation = _schedule(_calls);
        vm.expectRevert(_error);
        _executeProposal(operation);
        assertTrue(governance.isOperationReady(governance.hashOperation(operation)), "a reverted proposal stays ready");
    }

    function _liveImpl(ProxyAdmin _admin, TransparentUpgradeableProxy _proxy) internal view returns (address) {
        return _admin.getProxyImplementation(ITransparentUpgradeableProxy(address(_proxy)));
    }

    /// @dev What a refused proposal must leave: the CTM at its version and release with nothing
    ///      committed, and both domains' proxies where they were.
    function _assertNothingApplied() internal view {
        assertEq(chainContractAddress.protocolVersion(), 0, "the CTM version must not move");
        assertEq(chainContractAddress.upgradeTransition(0), address(0), "no transition must be committed");
        assertEq(chainContractAddress.currentRelease(), address(fromRelease), "the release must not move");
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOld, "the core leg must not stand");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOld, "the infrastructure leg must not stand");
    }

    // ─────────────────────────────── happy paths ───────────────────────────────

    /// @dev One proposal applies the core leg, then the CTM infrastructure rows, then the version
    ///      commit and release pin, each leg emitting its domain event.
    function test_bundle_appliesEveryLegInCanonicalOrder() public {
        uint256 oldVersion = chainContractAddress.protocolVersion();
        IGovernance.Operation memory proposal = _schedule(_fullBundle(address(transition)));

        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit ProxyUpgradeRowLib.ProxyImplementationUpgraded(address(ecosystemProxy), implNew);
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit ICoreUpgradeExecutor.L1UpgradeApplied(address(coreTransition));
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ProxyUpgradeRowLib.ProxyImplementationUpgraded(address(ctmDomainProxy), implNew);
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ICTMUpgradeExecutor.CTMInfrastructureUpgradeApplied(address(infrastructure));
        vm.expectEmit(true, true, true, true, address(chainContractAddress));
        emit IChainTypeManager.NewProtocolVersion(oldVersion, newVersion);
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ICTMUpgradeExecutor.CTMUpgradeApplied(address(transition), oldVersion, newVersion);
        vm.expectEmit(true, true, true, true, address(governance));
        emit IGovernance.OperationExecuted(governance.hashOperation(proposal));
        _executeProposal(proposal);

        assertEq(chainContractAddress.protocolVersion(), newVersion);
        assertEq(chainContractAddress.upgradeTransition(oldVersion), address(transition));
        assertEq(chainContractAddress.currentRelease(), address(release));
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implNew, "the core row must be applied");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implNew, "the CTM-domain row must be applied");
        _assertTransitionApplied(chainContractAddress, ICTMTransition(address(transition)), address(ctmExecutor));
    }

    /// @dev A core-only upgrade is one call and buys no chain-version edge.
    function test_coreOnlyBundle_appliesTheCoreLegAndMovesNoVersion() public {
        IGovernance.Operation memory proposal = _schedule(_bundle(_coreLeg(address(coreTransition))));
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit ICoreUpgradeExecutor.L1UpgradeApplied(address(coreTransition));
        _executeProposal(proposal);

        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implNew, "the core leg applied");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOld, "the CTM domain is untouched");
        assertEq(chainContractAddress.protocolVersion(), 0, "no chain-version edge was bought");
        assertEq(chainContractAddress.currentRelease(), address(fromRelease), "nor a release");
    }

    /// @dev An infrastructure-only upgrade replaces CTM-domain implementations and moves no version:
    ///      not the CTM's version, release or deadlines, and commits no transition.
    function test_infrastructureOnlyBundle_movesNoVersion() public {
        uint256 deadlineBefore = chainContractAddress.protocolVersionDeadline(0);
        IGovernance.Operation memory proposal = _schedule(_bundle(_infrastructureLeg(address(infrastructure))));
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ICTMUpgradeExecutor.CTMInfrastructureUpgradeApplied(address(infrastructure));
        _executeProposal(proposal);

        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implNew, "the CTM-domain row applied");
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOld, "the ecosystem is untouched");
        assertEq(chainContractAddress.protocolVersion(), 0, "the CTM version must not move");
        assertEq(chainContractAddress.currentRelease(), address(fromRelease), "nor its release");
        assertEq(chainContractAddress.upgradeTransition(0), address(0), "nor may a transition be committed");
        assertEq(chainContractAddress.protocolVersionDeadline(0), deadlineBefore, "nor a deadline");
    }

    /// @dev A transition-only upgrade is the one commit.
    function test_transitionOnlyBundle_commitsTheTransition() public {
        _executeProposal(_schedule(_bundle(_transitionLeg(address(transition)))));
        assertEq(chainContractAddress.upgradeTransition(0), address(transition));
        assertEq(chainContractAddress.protocolVersion(), newVersion);
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOld, "no core leg was named");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOld, "no infrastructure leg was named");
    }

    /// @dev No migration pause is involved: the commit runs with none held and pauses nothing, and an
    ///      ecosystem pause governance holds for incident control is left exactly as it was.
    function test_bundle_neitherNeedsNorTouchesMigrationPauses() public {
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)), "fixture: unpaused");
        _executeProposal(_schedule(_fullBundle(address(transition))));
        assertEq(chainContractAddress.protocolVersion(), newVersion, "commits without a pause");
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)), "and pauses nothing");

        vm.prank(governor);
        chainAssetHandler.pauseMigration();
        address appliedRelease = address(release);
        newVersion = SemVer.packSemVer(0, 2, 0);
        release = _deployRelease(4, newVersion);
        CTMTransition next = _deployTransitionFrom(880, appliedRelease);
        _executeProposal(_schedule(_bundle(_transitionLeg(address(next)))));
        assertEq(chainContractAddress.protocolVersion(), newVersion, "commits under an ecosystem pause too");
        assertTrue(chainAssetHandler.migrationPausedFor(address(chainContractAddress)), "which it leaves in place");
        assertFalse(chainAssetHandler.ctmMigrationPaused(address(chainContractAddress)), "and takes no CTM pause");
    }

    // ─────────────────────────── authority ───────────────────────────

    /// @dev Every leg is owner-gated: neither a stranger nor the executors' previous owner may drive
    ///      them once governance holds the executors.
    function test_revertWhen_aLegIsSentOutsideTheProposal() public {
        address[2] memory callers = [makeAddr("stranger"), governor];
        for (uint256 i = 0; i < callers.length; ++i) {
            vm.startPrank(callers[i]);
            vm.expectRevert("Ownable: caller is not the owner");
            coreExecutor.applyL1Upgrade(coreTransition);
            vm.expectRevert("Ownable: caller is not the owner");
            ctmExecutor.applyInfrastructureUpgrade(infrastructure);
            vm.expectRevert("Ownable: caller is not the owner");
            ctmExecutor.applyCTMUpgrade(ICTMTransition(address(transition)));
            vm.stopPrank();
        }
        _assertNothingApplied();
    }

    /// @dev An executor that does not (yet) own its CTM cannot commit on it — the pre-bootstrap
    ///      state — and the legs applied before the commit are rolled back with it.
    function test_revertWhen_theExecutorDoesNotOwnItsCTM() public {
        Call[] memory giveAway = new Call[](1);
        giveAway[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (governor))
        });
        Call[] memory forwarded = new Call[](1);
        forwarded[0] = Call({
            target: address(ctmExecutor),
            value: 0,
            data: abi.encodeCall(IUpgradeExecutorBase.forward, (giveAway))
        });
        _executeProposal(_schedule(forwarded));
        vm.prank(governor);
        Ownable2Step(address(chainContractAddress)).acceptOwnership();

        _expectProposalRevert(_fullBundle(address(transition)), bytes("Ownable: caller is not the owner"));
        _assertNothingApplied();
    }

    // ─────────────────────────── all or nothing ───────────────────────────

    /// @dev The FINAL leg failing rolls back every earlier swap of the proposal: here the
    ///      transition's L2 delegate was never published on the CTM's supplier, after the core and
    ///      infrastructure legs already swapped their proxies.
    function test_revertWhen_theFinalLegFails_everyEarlierLegIsRolledBack() public {
        bytes memory unpublishedDelegate = hex"de2f";
        CTMTransition unpublished = _deployTransitionWithDelegate(
            777,
            chainContractAddress.currentRelease(),
            unpublishedDelegate
        );
        assertEq(bytecodesSupplier.evmPublishingBlock(keccak256(unpublishedDelegate)), 0, "fixture: not yet published");

        IGovernance.Operation memory proposal = _expectProposalRevert(
            _fullBundle(address(unpublished)),
            abi.encodeWithSelector(L2BytecodeNotPublished.selector, keccak256(unpublishedDelegate))
        );
        _assertNothingApplied();

        // Publishing the missing dependency makes the very same proposal executable, every leg.
        L2PlanFixtures.publish(bytecodesSupplier, L2PlanFixtures.codes(unpublishedDelegate));
        _executeProposal(proposal);
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implNew, "the core leg applies");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implNew, "and the infrastructure leg");
        assertEq(chainContractAddress.protocolVersion(), newVersion, "and the version commit");
    }

    /// @dev A duplicated transition leg fails at its second commit (the release edge has moved), and
    ///      the first commit and the swaps before it are rolled back with it.
    function test_revertWhen_theTransitionLegIsDuplicated() public {
        Call[] memory calls = new Call[](4);
        Call[] memory full = _fullBundle(address(transition));
        calls[0] = full[0];
        calls[1] = full[1];
        calls[2] = full[2];
        calls[3] = full[2];
        _expectProposalRevert(
            calls,
            abi.encodeWithSelector(TransitionReleaseMismatch.selector, address(fromRelease), address(release))
        );
        _assertNothingApplied();
    }

    /// @dev A CTM-domain row whose proxy sits at an implementation the row does not know fails the
    ///      source check; the core leg ran FIRST in the same proposal and is rolled back too.
    function test_revertWhen_aCtmRowDepartsFromAnUnexpectedImplementation() public {
        // Something moved the CTM-domain proxy on before the proposal ran (an owner raw call
        // through the executor, which owns the admin).
        Call[] memory move = new Call[](1);
        move[0] = Call({
            target: address(ctmProxyAdmin),
            value: 0,
            data: abi.encodeCall(ProxyAdmin.upgrade, (ITransparentUpgradeableProxy(address(ctmDomainProxy)), implOther))
        });
        Call[] memory forwarded = new Call[](1);
        forwarded[0] = Call({
            target: address(ctmExecutor),
            value: 0,
            data: abi.encodeCall(IUpgradeExecutorBase.forward, (move))
        });
        _executeProposal(_schedule(forwarded));

        _expectProposalRevert(
            _fullBundle(address(transition)),
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ctmDomainProxy), implOld, implOther)
        );
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOther, "the offending proxy is left where it was");
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOld, "the core leg is rolled back");
        assertEq(chainContractAddress.upgradeTransition(0), address(0), "nothing is committed");
    }

    /// @dev A row whose swap does not END at its `implNew` (the reinitializer re-points the proxy)
    ///      fails its leg's own verification, so nothing of the proposal stands — in either domain.
    function test_revertWhen_aRowEndsOffItsTarget() public {
        address repointing = address(new SelfRepointingImpl(implOther));
        ProxyUpgradeRow memory repointingRow = ProxyUpgradeRow({
            proxy: address(ctmDomainProxy),
            expectedOldImpl: implOld,
            implNew: repointing,
            callInitializeUpgrade: true
        });
        ProxyUpgradeTransition repointingInfrastructure = _deployCTMInfrastructureTransition(repointingRow);
        _expectProposalRevert(
            _bundle(
                _coreLeg(address(coreTransition)),
                _infrastructureLeg(address(repointingInfrastructure)),
                _transitionLeg(address(transition))
            ),
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ctmDomainProxy), repointing, implOther)
        );
        _assertNothingApplied();

        repointingRow.proxy = address(ecosystemProxy);
        ProxyUpgradeTransition repointingCore = _deployCoreTransition(repointingRow);
        _expectProposalRevert(
            _bundle(_coreLeg(address(repointingCore)), _transitionLeg(address(transition))),
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ecosystemProxy), repointing, implOther)
        );
        _assertNothingApplied();
    }

    // ─────────────────────────── domains and substituted objects ───────────────────────────

    /// @dev Each executor applies only its own domain's objects: a Core-domain object handed to the
    ///      CTM executor (or the reverse) is refused, and the legs before it are rolled back.
    function test_revertWhen_aLegNamesTheOtherDomainsObject() public {
        _expectProposalRevert(
            _bundle(_coreLeg(address(coreTransition)), _infrastructureLeg(address(coreTransition))),
            abi.encodeWithSelector(
                ProxyUpgradeDomainMismatch.selector,
                uint8(ProxyUpgradeDomain.CTM),
                uint8(ProxyUpgradeDomain.Core)
            )
        );
        _assertNothingApplied();

        _expectProposalRevert(
            _bundle(_coreLeg(address(infrastructure))),
            abi.encodeWithSelector(
                ProxyUpgradeDomainMismatch.selector,
                uint8(ProxyUpgradeDomain.Core),
                uint8(ProxyUpgradeDomain.CTM)
            )
        );
        _assertNothingApplied();
    }

    /// @dev A CTM-domain object whose row names a proxy OUTSIDE the CTM domain (here an ecosystem
    ///      proxy) cannot apply: the CTM executor's admin does not administer that proxy, so reading
    ///      its implementation through that admin fails, and nothing of the proposal stands.
    function test_revertWhen_aCTMDomainObjectNamesAnEcosystemProxy() public {
        ProxyUpgradeTransition substituted = _deployCTMInfrastructureTransition(
            _row(address(ecosystemProxy), implOld, implNew)
        );
        IGovernance.Operation memory proposal = _schedule(
            _bundle(_infrastructureLeg(address(substituted)), _transitionLeg(address(transition)))
        );
        // The proxy answers a non-admin by delegating to its implementation, which has no
        // `implementation()` — a revert without data.
        vm.expectRevert(bytes(""));
        _executeProposal(proposal);
        _assertNothingApplied();
    }

    /// @dev A leg naming an undeployed object would otherwise "succeed" over nothing (a call into a
    ///      codeless address returns successfully), so each entrypoint refuses it.
    function test_revertWhen_aLegNamesAnUndeployedObject() public {
        address codeless = makeAddr("codelessObject");
        bytes memory noCode = abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless);
        _expectProposalRevert(_bundle(_coreLeg(codeless)), noCode);
        _expectProposalRevert(_bundle(_coreLeg(address(coreTransition)), _infrastructureLeg(codeless)), noCode);
        _expectProposalRevert(
            _bundle(
                _coreLeg(address(coreTransition)),
                _infrastructureLeg(address(infrastructure)),
                _transitionLeg(codeless)
            ),
            noCode
        );
        _assertNothingApplied();
    }

    /// @dev Stale: a transition departing from a release the CTM has left (another upgrade moved it
    ///      on first) is refused, with nothing of the proposal's other legs applied.
    function test_revertWhen_theTransitionDepartsFromAReleaseTheCTMLeft() public {
        CTMTransition competing = _deployTransitionFrom(778, address(fromRelease));
        _executeProposal(_schedule(_bundle(_transitionLeg(address(competing)))));

        _expectProposalRevert(
            _fullBundle(address(transition)),
            abi.encodeWithSelector(TransitionReleaseMismatch.selector, address(fromRelease), address(release))
        );
        assertEq(chainContractAddress.upgradeTransition(0), address(competing), "the competing commit stands");
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOld, "the stale core leg never stands");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOld, "nor its CTM-domain row");
    }
}
