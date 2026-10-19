// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Call} from "contracts/governance/Common.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {ChainRouting} from "test-utils/ChainRouting.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {
    L2_ECOSYSTEM_CONTRACT_COUNT,
    L2EcosystemContract
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {AcceptingVerifier} from "contracts/dev-contracts/test/AcceptingVerifier.sol";
import {FixedDelegateCalldataComposer} from "contracts/dev-contracts/FixedDelegateCalldataComposer.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {PRIORITY_TX_MAX_GAS_LIMIT, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {ISelfDescribingFacet} from "contracts/state-transition/chain-interfaces/ISelfDescribingFacet.sol";
import {LiveRoutingDiverged, ProtocolIdMismatch, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {
    AuthoredL2Plan,
    GenesisFacet,
    L2UpgradePlan,
    ReleaseGenesisData,
    ReleaseManifest,
    TransitionManifest
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";

/// @notice The first full registry-driven upgrade, end to end: a real chain diamond is taken
///         v32 -> v33 entirely through the CTM-bound `CTMUpgradeExecutor`, with the facet
///         delta DERIVED from each hop's release pair and actually EXECUTED (facet cuts applied,
///         the real `DefaultUpgrade` engine delegatecalled, the L2 protocol upgrade transaction
///         committed on the chain).
/// @dev Abstract over the VM: the same two hops run against an Era CTM/chain
///      (`RegistryDrivenUpgradeEraTest`) and a ZKsyncOS CTM/chain
///      (`RegistryDrivenUpgradeZKsyncOSTest`). The virtual hooks below pin down every
///      per-VM difference: the fixture, the registry's `isZKsyncOS` flag, the L2 upgrade-tx
///      type the chain must commit, the force-deployment flavor and the genesis params the CTM
///      accepts.
/// @dev The fixture chain starts at protocol version 0, so "v32" is reached by a first
///      registry-driven hop (0.0.0 -> 0.32.0, L1-only: no facet changes, no L2 transaction, new
///      verifier). The second hop (0.32.0 -> 0.33.0) is the full minor upgrade: a real facet
///      replacement plus the composed L2 protocol upgrade transaction (nonce = 33). Two hops
///      also prove consecutive registry-driven upgrades sequence correctly.
/// @dev The registry is a storage-backed double (fixture addresses are dynamic), but everything
///      it pins here is real: live facet addresses/selectors, a real replacement `AdminFacet`,
///      the real `DefaultUpgrade`, real verifier contracts.
/// @dev Each hop is committed by governance's `applyCTMUpgrade` on the CTM executor
///      ({protocol-docs/ecosystem-upgrade-coordination.md}); `upgradeChain` then crosses the chain.
///      No ecosystem leg is named (the hops are CTM-only). Multi-leg governance bundles are covered
///      in UpgradeBundleExecution.t.sol.
abstract contract RegistryDrivenUpgradeTestBase is ChainTypeManagerTest {
    CTMUpgradeExecutor internal ctmExecutor;
    CTMTransition internal transitionV32;
    CTMTransition internal transitionV33;
    /// @dev The v33 hop's pinned delegate-calldata composer: a test-only stand-in returning
    ///      `DELEGATE_CALLDATA` regardless of its inputs (there is no real L2 migration behind the
    ///      dummy delegate), so what this suite proves is that the chain-side path composes THROUGH
    ///      the pinned composer — not what a version's composer produces.
    FixedDelegateCalldataComposer internal delegateComposer;

    address internal chainAddress;
    address internal newAdminFacet;
    address internal verifierV32;
    address internal verifierV33;
    address internal defaultUpgrade;

    uint256 internal constant V32 = uint256(32) << 32; // 0.32.0
    uint256 internal constant V33 = uint256(33) << 32; // 0.33.0
    bytes internal constant DELEGATE_CALLDATA = hex"beef";

    // Dummy EVM bytecodes standing in for the v33 hop's L2 artifacts (see {L2PlanFixtures}): the
    // upgrade delegate (authored Unsafe extra) and the L2Bridgehub system-proxy row the v33
    // release's table carries (implementation + proxy shell). All three are factory deps.
    bytes internal constant L2_DELEGATE_CODE = hex"c0de01";
    bytes internal constant L2_BRIDGEHUB_IMPL_CODE = hex"c0de02";
    bytes internal constant L2_SYSTEM_PROXY_CODE = hex"c0de03";

    // ---------------------------------------------------------------------------------------
    // Per-VM hooks
    // ---------------------------------------------------------------------------------------

    /// @dev Deploys the CTM fixture (ecosystem + ChainTypeManager) for the VM under test.
    function _deployFixture() internal virtual;

    /// @dev The registry's `isZKsyncOS()` flag; it selects the composed L2 upgrade-tx type.
    function _isZKsyncOSVariant() internal pure virtual returns (bool);

    /// @dev The L2 upgrade-transaction type the chain must commit for this VM.
    function _expectedL2UpgradeTxType() internal pure virtual returns (uint256);

    /// @dev The force-deployment flavor the transition DERIVES for the target release's table rows
    ///      (VM identity is read from the release's pinned DiamondInit).
    function _l2DeploymentType() internal pure virtual returns (IComplexUpgrader.ContractUpgradeType);

    /// @dev The `genesisBatchCommitment` the registry pins in its genesis params — the release
    ///      the commit installs feeds it to chain creation, which ZKsyncOS CTMs only
    ///      accept as exactly `bytes32(uint256(1))`.
    function _registryGenesisBatchCommitment() internal pure virtual returns (bytes32);

    // ---------------------------------------------------------------------------------------
    // Shared fixture
    // ---------------------------------------------------------------------------------------

    function setUp() public {
        _deployFixture();
        // Fixture sanity: the CTM under test must match the VM variant. The chain-side
        // `s.zksyncOS` flag is asserted end-to-end below — the chain only accepts the upgrade
        // transaction type of its own VM (`InvalidTxType` otherwise).
        assertEq(
            IChainTypeManager(address(chainContractAddress)).isZKsyncOS(),
            _isZKsyncOSVariant(),
            "fixture must deploy the CTM of the VM under test"
        );
        chainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(chainAddress);

        // The CTM executor, owned by governance — the shape the v35 bootstrap leaves behind.
        ctmExecutor = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(address(chainContractAddress)),
            new ProxyAdmin()
        );

        // Real v33 artifacts: a fresh AdminFacet implementation (same selectors, new address)
        // and the plain DefaultUpgrade as the upgrade-init contract.
        newAdminFacet = address(new AdminFacet(block.chainid, RollupDAManager(address(0))));
        defaultUpgrade = address(new DefaultUpgrade());
        verifierV32 = address(new AcceptingVerifier());
        verifierV33 = address(new AcceptingVerifier());
        delegateComposer = new FixedDelegateCalldataComposer(DELEGATE_CALLDATA);

        // Hand CTM ownership to the executor through its fixed entrypoint, then perform one raw
        // admin action through the owner-gated escape hatch (exactly what it exists for): raise the
        // chain's priority-tx gas limit.
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(ctmExecutor));
        vm.prank(governor);
        ctmExecutor.acceptCTMOwnership();
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setPriorityTxMaxGasLimit, (chainId, PRIORITY_TX_MAX_GAS_LIMIT))
        });
        vm.prank(governor);
        ctmExecutor.forward(calls);

        // The chain's genesis upgrade transaction is still pending: on a real chain the server
        // finalizes it by executing the first batch, which is out of scope for an L1 unit test.
        // Clearing it via the UtilsFacet simulates exactly that batch execution; without it any
        // subsequent minor upgrade correctly reverts with PreviousUpgradeNotFinalized.
        UtilsFacet(chainAddress).util_setL2SystemContractsUpgradeTxHash(bytes32(0));

        // Every bytecode the v33 hop installs must be published on the CTM's supplier before
        // governance commits the edge — the prepare pipeline's publish step.
        assertEq(chainContractAddress.L1_BYTECODES_SUPPLIER(), address(bytecodesSupplier));
        L2PlanFixtures.publish(
            bytecodesSupplier,
            L2PlanFixtures.codes(L2_DELEGATE_CODE, L2_BRIDGEHUB_IMPL_CODE, L2_SYSTEM_PROXY_CODE)
        );

        // The first hop departs from the fixture CTM's genesis (current) release; V33 then
        // transitions from the V32 release the first hop pinned.
        transitionV32 = _makeTransition(V32, verifierV32, chainContractAddress.currentRelease(), address(0));
        transitionV33 = _makeTransition(V33, verifierV33, transitionV32.newRelease(), newAdminFacet);
    }

    /// @inheritdoc ChainTypeManagerTest
    /// @dev The genesis release, describing the chain's routing at version 0: the fixture chain is
    ///      created from it and hop 1 departs from it. Installing it validates that every facet
    ///      self-describes, which the fixture's test facets only do once mocked.
    function _fixtureGenesisRelease() internal virtual override returns (address) {
        _mockFacetSelfDescriptions(facetCuts);
        return address(new CTMRelease(_releaseManifest(address(0), address(testnetVerifier), 0)));
    }

    /// @dev One release's full manifest at `_protocolVersion`: the fixture's routing (AdminFacet
    ///      swapped for `_adminFacet` when nonzero), the verifier, genesis params (with the fixture's
    ///      real genesis upgrade, since the fixture chain is created from a release) and the L2
    ///      bytecode table.
    ///      Hop 1 changes only the verifier, so its target release differs from genesis in that
    ///      one field and the DERIVED facet/deployment delta is empty — an L1-only upgrade. The
    ///      v33 release (nonzero `_adminFacet`) also carries one table row, the L2Bridgehub
    ///      implementation behind the shared shell, which the v33 transition derives as a
    ///      system-proxy upgrade. Every release names the same shell, which no edge may change.
    function _releaseManifest(
        address _adminFacet,
        address _verifier,
        uint256 _protocolVersion
    ) internal view returns (ReleaseManifest memory) {
        bytes[] memory l2BytecodeInfos = new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT);
        bytes memory l2SystemProxyBytecodeInfo = L2PlanFixtures.bytecodeInfo(L2_SYSTEM_PROXY_CODE);
        if (_adminFacet != address(0)) {
            l2BytecodeInfos[uint256(L2EcosystemContract.L2Bridgehub)] = L2PlanFixtures.bytecodeInfo(
                L2_BRIDGEHUB_IMPL_CODE
            );
        }
        return
            ReleaseManifest({
                protocolVersion: _protocolVersion,
                diamondInit: diamondInit,
                verifier: _verifier,
                genesisUpgrade: address(genesisUpgradeContract),
                genesisFacets: _releaseFacets(_adminFacet),
                genesis: ReleaseGenesisData({
                    fixedForceDeploymentsData: L2PlanFixtures.forceDeploymentsData(
                        l2BytecodeInfos,
                        l2SystemProxyBytecodeInfo
                    ),
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisIndexRepeatedStorageChanges: 54
                }),
                l2BytecodeInfos: l2BytecodeInfos,
                l2SystemProxyBytecodeInfo: l2SystemProxyBytecodeInfo
            });
    }

    /// @dev The complete facet set of one release: the fixture's facets, with the AdminFacet
    ///      row pointing at `_adminFacet` when nonzero. Routing is not stored — every consumer
    ///      reads it from the pinned facet's own self-description.
    function _releaseFacets(address _adminFacet) internal view returns (GenesisFacet[] memory genesisFacets) {
        genesisFacets = new GenesisFacet[](facetCuts.length);
        for (uint256 i = 0; i < facetCuts.length; ++i) {
            bool replaced = _adminFacet != address(0) && facetCuts[i].facet == facetCuts[1].facet;
            address facet = replaced ? _adminFacet : facetCuts[i].facet;
            genesisFacets[i] = GenesisFacet({facet: facet, isFreezable: facetCuts[i].isFreezable});
        }
    }

    /// @dev Builds one hop's release + transition. The release describes the COMPLETE post-hop
    ///      chain state (explicit facet routing, inline pins); the transition's facet delta is
    ///      DERIVED from `(fromRelease, newRelease)` at initialization — nothing is hand-authored.
    ///      When `_newAdminFacet` is zero the target release equals the source routing (empty
    ///      derived delta -> L1-only upgrade with empty cuts); otherwise the derived delta replaces
    ///      the chain's REAL AdminFacet by the given implementation, and the hop also carries an L2
    ///      side — the table-derived L2Bridgehub row plus the authored upgrade delegate — making
    ///      it a full minor upgrade.
    function _makeTransition(
        uint256 _newVersion,
        address _verifier,
        address _fromRelease,
        address _newAdminFacet
    ) internal returns (CTMTransition transition) {
        address release = address(new CTMRelease(_releaseManifest(_newAdminFacet, _verifier, _newVersion)));

        // A nonempty L2 plan MUST carry a delegate: `L2ComplexUpgrader` always ends with the final
        // delegatecall, so a deployments-only plan would revert on L2. The delegate is the one
        // authored bytecode, its calldata is defined by the pinned composer, and the object
        // constructs its address and every factory dependency the hop installs (the delegate,
        // the table row's implementation and proxy shell).
        AuthoredL2Plan memory l2Plan = _newAdminFacet != address(0)
            ? L2PlanFixtures.delegatePlan(L2_DELEGATE_CODE, address(delegateComposer))
            : L2PlanFixtures.emptyPlan();

        transition = new CTMTransition(
            TransitionManifest({
                fromRelease: _fromRelease,
                newRelease: release,
                upgradeEngine: defaultUpgrade,
                oldProtocolVersionDeadline: 1000,
                upgradeTimestamp: 0,
                l2Plan: l2Plan
            })
        );
    }

    /// @dev Governance commits the hop on the CTM.
    function _commitHop(CTMTransition _transition) internal {
        vm.prank(governor);
        ctmExecutor.applyCTMUpgrade(ICTMTransition(address(_transition)));
        assertEq(
            chainContractAddress.upgradeTransition(_transition.oldProtocolVersion()),
            address(_transition),
            "governance must commit the hop"
        );
    }

    /// @dev The whole hop: commit, then cross the chain.
    function _runHop(CTMTransition _transition) internal {
        _commitHop(_transition);
        vm.prank(governor);
        ctmExecutor.upgradeChain(ICTMTransition(address(_transition)), chainId);
    }

    function test_registryDrivenUpgrade_v32ThenV33_endToEnd() public {
        // Hop 1 (0.0.0 -> 0.32.0): L1-only registry-driven upgrade — the target release differs
        // from genesis only in the verifier, so the DERIVED facet delta is empty and no L2
        // transaction is composed. The cut executes on the real chain with the real
        // DefaultUpgrade init.
        _runHop(transitionV32);

        assertEq(chainContractAddress.protocolVersion(), V32, "hop 1 must bump the CTM to v32");
        assertEq(IGetters(chainAddress).getProtocolVersion(), V32, "hop 1 must bump the chain to v32");
        assertEq(address(IGetters(chainAddress).getVerifier()), verifierV32, "hop 1 must install the v32 verifier");
        assertEq(
            IGetters(chainAddress).getL2SystemContractsUpgradeTxHash(),
            bytes32(0),
            "an L1-only upgrade must not set an L2 upgrade transaction"
        );

        // Hop 2 (0.32.0 -> 0.33.0): the full minor upgrade — AdminFacet actually replaced and
        // the composed L2 protocol upgrade transaction (nonce = 33) committed on the chain.
        _runHop(transitionV33);

        assertEq(chainContractAddress.protocolVersion(), V33, "hop 2 must bump the CTM to v33");
        assertEq(IGetters(chainAddress).getProtocolVersion(), V33, "hop 2 must bump the chain to v33");
        (, uint32 minor, ) = SemVer.unpackSemVer(uint96(V33));
        assertEq(minor, 33);
        assertEq(address(IGetters(chainAddress).getVerifier()), verifierV33, "hop 2 must install the v33 verifier");
        assertEq(
            IGetters(chainAddress).facetAddress(IAdmin.acceptAdmin.selector),
            newAdminFacet,
            "the AdminFacet must be re-pointed to the v33 implementation"
        );

        // The executed L2 plan is the table-DERIVED L2Bridgehub row followed by the authored
        // delegate, and the delegatecall targets that delegate at its bytecode-derived address.
        L2UpgradePlan memory plan = transitionV33.l2Plan();
        assertEq(plan.deployments.length, 2, "derived row + authored delegate");
        assertTrue(plan.deployments[0].upgradeType == _l2DeploymentType(), "table row derives the VM's flavor");
        assertEq(plan.deployments[0].newAddress, L2_BRIDGEHUB_ADDR, "table row lands on the member's fixed address");
        assertEq(
            plan.deployments[0].deployedBytecodeInfo,
            L2PlanFixtures.systemProxyRow(L2_BRIDGEHUB_IMPL_CODE, L2_SYSTEM_PROXY_CODE)
        );
        assertTrue(
            plan.deployments[1].upgradeType == IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment
        );
        assertEq(plan.deployments[1].newAddress, plan.delegateTo, "the delegate is the authored Unsafe extra");
        assertEq(plan.delegateComposer, address(delegateComposer), "the pinned composer defines the delegate calldata");
        assertEq(plan.factoryDepHashes.length, 3, "delegate + implementation + proxy shell");

        // The chain composed on its own Bridgehub (`s.bridgehub`), which is the CTM's — the one
        // this fixture deployed. Re-composing against it must reproduce the committed transaction.
        // (Read through the fixture's UtilsFacet: the fixture diamond does not route `getBridgehub`.)
        assertEq(
            UtilsFacet(chainAddress).util_getBridgehub(),
            address(bridgehub),
            "the chain composes on its Bridgehub"
        );
        assertEq(chainContractAddress.BRIDGE_HUB(), address(bridgehub));

        // The committed L2 upgrade transaction is exactly the registry-composed one FOR THIS
        // CHAIN (`s.chainId`), carrying the ZKsync OS upgrade-transaction type (126) and, as the
        // delegate calldata, what the pinned composer composed.
        L2CanonicalTransaction memory expectedTx = CTMUpgradeComposer.buildL2UpgradeTx(
            ICTMTransition(address(transitionV33)),
            address(bridgehub),
            chainId
        );
        assertEq(expectedTx.factoryDeps.length, 3, "the L2 transaction carries every installed bytecode");
        assertEq(expectedTx.txType, _expectedL2UpgradeTxType(), "the upgrade tx must carry the VM's upgrade tx type");
        assertEq(expectedTx.nonce, 33, "upgrade tx nonce must equal the new minor version");
        assertEq(
            expectedTx.data,
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (plan.deployments, plan.delegateTo, DELEGATE_CALLDATA)
            ),
            "the delegate is called with the composer's calldata"
        );
        bytes32 committedHash = IGetters(chainAddress).getL2SystemContractsUpgradeTxHash();
        assertEq(
            committedHash,
            keccak256(abi.encode(expectedTx)),
            "the chain must commit the registry-composed L2 upgrade transaction"
        );
        // The off-chain tooling's read of the same composition (the anvil runner relays exactly
        // this): the transition forwards to the pinned engine, which serves what the chain committed.
        assertEq(
            keccak256(abi.encode(transitionV33.l2UpgradeTx(address(bridgehub), chainId))),
            committedHash,
            "the transition must serve the committed transaction"
        );
        assertEq(
            keccak256(
                abi.encode(
                    DefaultUpgrade(defaultUpgrade).l2UpgradeTx(address(transitionV33), address(bridgehub), chainId)
                )
            ),
            committedHash,
            "the engine must serve the committed transaction"
        );
    }

    function test_revertWhen_hopReplayed() public {
        _runHop(transitionV32);

        // Replaying the chain upgrade of a completed hop fails the chain's own version check.
        vm.expectRevert(abi.encodeWithSelector(ProtocolIdMismatch.selector, V32, 0));
        vm.prank(governor);
        ctmExecutor.upgradeChain(ICTMTransition(address(transitionV32)), chainId);
    }

    /// @dev A chain's loupe routing against its release (the test-side {ChainRouting} check), across
    ///      every chain state this suite produces: freshly genesised, and having crossed a transition.
    ///      The v33 release replaces the AdminFacet ADDRESS (same selectors), so each side of the hop
    ///      is a missing-facet mismatch for the other side's release.
    function test_chainRoutingTracksTheLiveChain() public {
        CTMRelease genesisRelease = CTMRelease(chainContractAddress.currentRelease());
        CTMRelease releaseV33 = CTMRelease(transitionV33.newRelease());

        // Freshly genesised chain runs exactly its release's routing — and not yet the v33
        // release's, whose replacement AdminFacet is not installed.
        assertTrue(
            ChainRouting.matchesRelease(ICTMRelease(address(genesisRelease)), chainAddress),
            "genesis chain must match its release"
        );
        assertFalse(
            ChainRouting.matchesRelease(ICTMRelease(address(releaseV33)), chainAddress),
            "target release must not match pre-hop"
        );

        _runHop(transitionV32);
        _runHop(transitionV33);

        // After crossing, the chain matches the release it transitioned to; the departed
        // release (still routing the replaced AdminFacet address) no longer matches.
        assertTrue(
            ChainRouting.matchesRelease(ICTMRelease(address(releaseV33)), chainAddress),
            "post-hop chain must match the target release"
        );
        assertFalse(
            ChainRouting.matchesRelease(ICTMRelease(address(genesisRelease)), chainAddress),
            "departed release must not match"
        );

        // Same facet ADDRESS, different selector set: the check compares full selector sets, so
        // a drifted self-description fails even when the address is live. Mocked drift — with
        // real flows the release always reads the facet's own (matching) self-description.
        bytes4[] memory drifted = new bytes4[](1);
        drifted[0] = bytes4(uint32(0xdeadbeef));
        vm.mockCall(
            newAdminFacet,
            abi.encodeWithSelector(ISelfDescribingFacet.selectors.selector),
            abi.encode(drifted)
        );
        assertFalse(
            ChainRouting.matchesRelease(ICTMRelease(address(releaseV33)), chainAddress),
            "drifted selector set must not match"
        );
    }

    /// @dev Freezability is part of a release row but not of the loupe's `facets()` view, so the
    ///      routing check reads it per facet from the live diamond: a release pinning the live
    ///      addresses and selectors but the OPPOSITE freezability for any one facet must not match.
    function test_chainRoutingRejectsFreezabilityMismatch() public {
        // Control: the same manifest builder, unflipped, describes the live chain.
        ReleaseManifest memory manifest = _releaseManifest(address(0), address(testnetVerifier), 0);
        CTMRelease unflipped = new CTMRelease(manifest);
        assertTrue(
            ChainRouting.matchesRelease(ICTMRelease(address(unflipped)), chainAddress),
            "the unflipped manifest must match the live chain"
        );

        for (uint256 i = 0; i < manifest.genesisFacets.length; ++i) {
            ReleaseManifest memory flippedManifest = _releaseManifest(address(0), address(testnetVerifier), 0);
            flippedManifest.genesisFacets[i].isFreezable = !flippedManifest.genesisFacets[i].isFreezable;
            CTMRelease flipped = new CTMRelease(flippedManifest);

            // Addresses and selectors still match; only this row's freezability disagrees with
            // what the diamond installed.
            assertEq(
                IGetters(chainAddress).isFacetFreezable(manifest.genesisFacets[i].facet),
                manifest.genesisFacets[i].isFreezable,
                "the live diamond must carry the original freezability"
            );
            assertFalse(
                ChainRouting.matchesRelease(ICTMRelease(address(flipped)), chainAddress),
                "a release with one facet's freezability flipped must not match"
            );
        }
    }

    /// @dev Governance commits the hop but never executes the chain upgrade. Even once the
    ///      old-version deadline (1000, pinned by the transition) has passed, only governance or the
    ///      chain's own admin decides when the chain crosses.
    function test_revertWhen_strangerUpgradesChainAfterDeadline() public {
        _commitHop(transitionV32);
        uint256 versionBefore = IGetters(chainAddress).getProtocolVersion();

        address keeper = makeAddr("keeper");
        vm.warp(1001);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, keeper));
        vm.prank(keeper);
        ctmExecutor.upgradeChain(ICTMTransition(address(transitionV32)), chainId);

        assertEq(IGetters(chainAddress).getProtocolVersion(), versionBefore, "the chain did not cross");
    }

    /// @dev Upgrading is the chain's own decision, so its admin may execute the committed hop at
    ///      any point in the window; a stranger is refused
    ///      (`test_revertWhen_strangerUpgradesChainBeforeDeadline` in CTMUpgradeExecutor.t.sol).
    function test_chainAdminUpgradesTheirOwnChainBeforeTheDeadline() public {
        _commitHop(transitionV32);

        vm.warp(999);
        vm.prank(IGetters(chainAddress).getAdmin());
        ctmExecutor.upgradeChain(ICTMTransition(address(transitionV32)), chainId);

        assertEq(IGetters(chainAddress).getProtocolVersion(), V32, "admin-executed upgrade must land");
    }
}

/// @notice The registry-driven upgrade run against the shared CTM fixture: the chain commits
///         a `ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE` (126) transaction with a
///         `ZKsyncOSSystemProxyUpgrade` deployment, and the registry's genesis params carry the
///         `genesisBatchCommitment == 1` that `ChainTypeManager` enforces.
contract RegistryDrivenUpgradeConcreteTest is ChainTypeManagerTest, RegistryDrivenUpgradeTestBase {
    /// @dev Positions in the fixture's `facetCuts` (`ChainTypeManagerTest.deploy`): two facets of
    ///      equal freezability whose selectors the upgrade path never calls.
    uint256 internal constant MAILBOX_FACET_INDEX = 4;
    uint256 internal constant MIGRATOR_FACET_INDEX = 5;

    function _deployFixture() internal override {
        deploy();
    }

    function _fixtureGenesisRelease()
        internal
        override(ChainTypeManagerTest, RegistryDrivenUpgradeTestBase)
        returns (address)
    {
        return RegistryDrivenUpgradeTestBase._fixtureGenesisRelease();
    }

    function _isZKsyncOSVariant() internal pure override returns (bool) {
        return true;
    }

    function _expectedL2UpgradeTxType() internal pure override returns (uint256) {
        return ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE;
    }

    function _l2DeploymentType() internal pure override returns (IComplexUpgrader.ContractUpgradeType) {
        return IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade;
    }

    function _registryGenesisBatchCommitment() internal pure override returns (bytes32) {
        // ChainTypeManager requires the genesis batch commitment to be exactly 1.
        return bytes32(uint256(1));
    }

    /// @dev The derived cuts remove the departing release's routing, not the live one, so a chain
    ///      a CTM-owner recovery cut left off that routing cannot take the transition: it would keep
    ///      the recovery's routing under the new release. Undoing the recovery unblocks it.
    function test_revertWhen_liveRoutingDivergedFromTheDepartingRelease() public {
        _commitHop(transitionV32);
        bytes4[] memory extra = new bytes4[](1);
        extra[0] = bytes4(uint32(0xdeadbeef));
        address recoveryFacet = address(new AcceptingVerifier());
        _recoveryCut(
            Diamond.FacetCut({facet: recoveryFacet, action: Diamond.Action.Add, isFreezable: false, selectors: extra})
        );

        vm.prank(governor);
        vm.expectRevert(LiveRoutingDiverged.selector);
        ctmExecutor.upgradeChain(ICTMTransition(address(transitionV32)), chainId);

        _recoveryCut(
            Diamond.FacetCut({facet: address(0), action: Diamond.Action.Remove, isFreezable: false, selectors: extra})
        );
        vm.prank(governor);
        ctmExecutor.upgradeChain(ICTMTransition(address(transitionV32)), chainId);
        assertEq(IGetters(chainAddress).getProtocolVersion(), V32, "the restored chain takes the transition");
    }

    /// @dev The departing facets all stay live and route what they self-describe, but one also
    ///      routes an extra selector: only the per-facet count shows it, and the reinstall, which
    ///      removes the described selectors only, would leave it routed.
    function test_revertWhen_aRecoveryCutAddedASelectorToAReleaseFacet() public {
        _commitHop(transitionV32);
        Diamond.FacetCut memory migrator = facetCuts[MIGRATOR_FACET_INDEX];
        bytes4[] memory extra = new bytes4[](1);
        extra[0] = bytes4(uint32(0xdeadbeef));
        _recoveryCut(
            Diamond.FacetCut({
                facet: migrator.facet,
                action: Diamond.Action.Add,
                isFreezable: migrator.isFreezable,
                selectors: extra
            })
        );
        assertEq(IGetters(chainAddress).facetAddress(extra[0]), migrator.facet, "the recovery cut must route it");

        vm.prank(governor);
        vm.expectRevert(LiveRoutingDiverged.selector);
        ctmExecutor.upgradeChain(ICTMTransition(address(transitionV32)), chainId);
    }

    /// @dev Same facets and per-facet selector counts, but two facets of equal freezability swapped
    ///      one selector each: only the per-selector facet check tells this from the release.
    function test_revertWhen_aRecoveryCutSwappedSelectorsBetweenReleaseFacets() public {
        _commitHop(transitionV32);
        Diamond.FacetCut memory migrator = facetCuts[MIGRATOR_FACET_INDEX];
        Diamond.FacetCut memory mailbox = facetCuts[MAILBOX_FACET_INDEX];
        assertEq(migrator.isFreezable, mailbox.isFreezable, "the swap must not change freezability");
        bytes4[] memory toMailbox = new bytes4[](1);
        toMailbox[0] = migrator.selectors[0];
        bytes4[] memory toMigrator = new bytes4[](1);
        toMigrator[0] = mailbox.selectors[0];
        _recoveryCut(
            Diamond.FacetCut({
                facet: mailbox.facet,
                action: Diamond.Action.Replace,
                isFreezable: mailbox.isFreezable,
                selectors: toMailbox
            })
        );
        _recoveryCut(
            Diamond.FacetCut({
                facet: migrator.facet,
                action: Diamond.Action.Replace,
                isFreezable: migrator.isFreezable,
                selectors: toMigrator
            })
        );
        assertEq(IGetters(chainAddress).facetAddress(toMailbox[0]), mailbox.facet, "the first selector moved");
        assertEq(IGetters(chainAddress).facetAddress(toMigrator[0]), migrator.facet, "the second selector moved");

        vm.prank(governor);
        vm.expectRevert(LiveRoutingDiverged.selector);
        ctmExecutor.upgradeChain(ICTMTransition(address(transitionV32)), chainId);
    }

    /// @dev Same facets, selectors and routing, but one facet reinstalled with the opposite
    ///      freezability. A single-selector `Replace` cannot do this (`Diamond` refuses mixed
    ///      freezability within a facet), so the recovery removes the whole facet and adds it back.
    function test_revertWhen_aRecoveryCutFlippedAReleaseFacetsFreezability() public {
        _commitHop(transitionV32);
        Diamond.FacetCut memory migrator = facetCuts[MIGRATOR_FACET_INDEX];
        _recoveryCut(
            Diamond.FacetCut({
                facet: address(0),
                action: Diamond.Action.Remove,
                isFreezable: false,
                selectors: migrator.selectors
            })
        );
        _recoveryCut(
            Diamond.FacetCut({
                facet: migrator.facet,
                action: Diamond.Action.Add,
                isFreezable: !migrator.isFreezable,
                selectors: migrator.selectors
            })
        );
        assertEq(
            IGetters(chainAddress).isFacetFreezable(migrator.facet),
            !migrator.isFreezable,
            "the recovery must flip the facet's freezability"
        );

        vm.prank(governor);
        vm.expectRevert(LiveRoutingDiverged.selector);
        ctmExecutor.upgradeChain(ICTMTransition(address(transitionV32)), chainId);
    }

    /// @dev A CTM-owner `executeUpgrade` on the fixture chain, through the executor's escape hatch.
    function _recoveryCut(Diamond.FacetCut memory _cut) internal {
        Diamond.FacetCut[] memory cuts = new Diamond.FacetCut[](1);
        cuts[0] = _cut;
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(
                IChainTypeManager.executeUpgrade,
                (chainId, Diamond.DiamondCutData({facetCuts: cuts, initAddress: address(0), initCalldata: ""}))
            )
        });
        vm.prank(governor);
        ctmExecutor.forward(calls);
    }
}
