// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {ZKsyncOSChainTypeManagerSharedTest} from "../../state-transition/ChainTypeManager/_ZKsyncOSChainTypeManager_Shared.t.sol";
import {Call} from "contracts/governance/Common.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";

import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {EraTestnetVerifier} from "contracts/state-transition/verifiers/EraTestnetVerifier.sol";
import {IVerifierV2} from "contracts/state-transition/chain-interfaces/IVerifierV2.sol";
import {IVerifier} from "contracts/state-transition/chain-interfaces/IVerifier.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    PRIORITY_TX_MAX_GAS_LIMIT,
    SYSTEM_UPGRADE_L2_TX_TYPE,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE
} from "contracts/common/Config.sol";
import {ISelfDescribingFacet} from "contracts/state-transition/chain-interfaces/ISelfDescribingFacet.sol";
import {ProtocolIdMismatch} from "contracts/common/L1ContractErrors.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {
    GenesisFacet,
    L2UpgradePlan,
    ReleaseGenesisData,
    ReleaseManifest,
    TransitionManifest
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";

/// @notice The first full registry-driven upgrade, end to end: a real chain diamond is taken
///         v32 -> v33 entirely through the CTM-bound `CTMUpgradeExecutor`, with the facet/hash
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
abstract contract RegistryDrivenUpgradeTestBase is ChainTypeManagerTest {
    CTMUpgradeExecutor internal ctmExecutor;
    CTMTransition internal transitionV32;
    CTMTransition internal transitionV33;

    address internal chainAddress;
    address internal newAdminFacet;
    address internal verifierV32;
    address internal verifierV33;
    address internal defaultUpgrade;
    address internal genesisUpgradeAddr;

    uint256 internal constant V32 = uint256(32) << 32; // 0.32.0
    uint256 internal constant V33 = uint256(33) << 32; // 0.33.0

    // ---------------------------------------------------------------------------------------
    // Per-VM hooks
    // ---------------------------------------------------------------------------------------

    /// @dev Deploys the CTM fixture (ecosystem + ChainTypeManager) for the VM under test.
    function _deployFixture() internal virtual;

    /// @dev The registry's `isZKsyncOS()` flag; it selects the composed L2 upgrade-tx type.
    function _isZKsyncOSVariant() internal pure virtual returns (bool);

    /// @dev The L2 upgrade-transaction type the chain must commit for this VM.
    function _expectedL2UpgradeTxType() internal pure virtual returns (uint256);

    /// @dev The force-deployment flavor the registry pins for the L2 side of the upgrade.
    function _l2DeploymentType() internal pure virtual returns (IComplexUpgrader.ContractUpgradeType);

    /// @dev The pinned `deployedBytecodeInfo` — opaque on L1 (only decoded on L2), so any
    ///      VM-shaped payload is enough here.
    function _l2DeployedBytecodeInfo() internal pure virtual returns (bytes memory);

    /// @dev The `genesisBatchCommitment` the registry pins in its genesis params —
    ///      `applyCTMUpgrade` feeds it to `setChainCreationParams`, which ZKsyncOS CTMs only
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
        _mockMigrationPausedFromBridgehub();

        ctmExecutor = new CTMUpgradeExecutor(
            governor,
            makeAddr("emergencyUpgradeBoard"),
            IChainTypeManager(address(chainContractAddress)),
            Utils.transitionCodehash()
        );

        // Real v33 artifacts: a fresh AdminFacet implementation (same selectors, new address)
        // and the plain DefaultUpgrade as the upgrade-init contract.
        newAdminFacet = address(new AdminFacet(block.chainid, RollupDAManager(address(0))));
        defaultUpgrade = address(new DefaultUpgrade());
        verifierV32 = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
        verifierV33 = address(new EraTestnetVerifier(IVerifierV2(address(0)), IVerifier(address(0))));
        // The pinned genesisUpgrade must carry real code — the registry's codehash pin rejects a
        // codeless target — so etch a stand-in and pin its actual codehash below.
        genesisUpgradeAddr = makeAddr("genesisUpgrade");
        vm.etch(genesisUpgradeAddr, hex"600042");

        // Transitions require real releases on BOTH edges, so the fixture CTM's mocked genesis
        // release is replaced by a real one describing the chain's current routing — hop 1 then
        // departs from (and, being facet-neutral, also targets) exactly that release.
        address genesisRelease = address(new CTMRelease(_releaseManifest(address(0), address(testnetVerifier))));

        // Hand CTM ownership to the executor through its fixed entrypoint, then perform two raw
        // one-off admin actions through break-glass (exactly what the separately governed hatch
        // exists for): re-point currentRelease at the real genesis release and raise the chain's
        // priority-tx gas limit.
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(ctmExecutor));
        vm.prank(governor);
        ctmExecutor.acceptCTMOwnership();
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setCurrentRelease, (genesisRelease))
        });
        calls[1] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setPriorityTxMaxGasLimit, (chainId, PRIORITY_TX_MAX_GAS_LIMIT))
        });
        vm.prank(makeAddr("emergencyUpgradeBoard"));
        ctmExecutor.forward(calls);

        // The chain's genesis upgrade transaction is still pending: on a real chain the server
        // finalizes it by executing the first batch, which is out of scope for an L1 unit test.
        // Clearing it via the UtilsFacet simulates exactly that batch execution; without it any
        // subsequent minor upgrade correctly reverts with PreviousUpgradeNotFinalized.
        UtilsFacet(chainAddress).util_setL2SystemContractsUpgradeTxHash(bytes32(0));

        // The first hop departs from the fixture CTM's genesis (current) release; V33 then
        // transitions from the V32 release the first hop pinned.
        transitionV32 = _makeTransition(0, V32, verifierV32, chainContractAddress.currentRelease(), address(0));
        transitionV33 = _makeTransition(V32, V33, verifierV33, transitionV32.newRelease(), newAdminFacet);
    }

    /// @dev One release's full manifest: the fixture's routing (AdminFacet swapped for
    ///      `_adminFacet` when nonzero), the verifier, carried base-system hashes, genesis params.
    ///      Hop 1 changes only the verifier, so its target release differs from genesis in that
    ///      one field and the DERIVED facet/hash delta is empty — an L1-only upgrade.
    function _releaseManifest(address _adminFacet, address _verifier) internal returns (ReleaseManifest memory) {
        return
            ReleaseManifest({
                diamondInit: diamondInit,
                diamondInitCodehash: diamondInit.codehash,
                verifier: _verifier,
                verifierCodehash: _verifier.codehash,
                genesisUpgrade: genesisUpgradeAddr,
                genesisUpgradeCodehash: genesisUpgradeAddr.codehash,
                genesisFacets: _releaseFacets(_adminFacet),
                // Carried unchanged through every hop: the release pins the complete values, so
                // the derived hash changes are zero.
                genesis: ReleaseGenesisData({
                    bootloaderHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                    defaultAccountHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                    evmEmulatorHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                    fixedForceDeploymentsData: hex"f1f2",
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisBatchCommitment: _registryGenesisBatchCommitment(),
                    genesisIndexRepeatedStorageChanges: 54
                })
            });
    }

    /// @dev The complete facet routing of one release: the fixture's full facet set, with the
    ///      AdminFacet row pointing at `_adminFacet` when nonzero. The replaced row carries an
    ///      EMPTY selector list (self-describing facet) — the same source the transition's add
    ///      side resolves — so transition and release agree by construction.
    function _releaseFacets(address _adminFacet) internal view returns (GenesisFacet[] memory genesisFacets) {
        genesisFacets = new GenesisFacet[](facetCuts.length);
        for (uint256 i = 0; i < facetCuts.length; ++i) {
            bool replaced = _adminFacet != address(0) && facetCuts[i].facet == facetCuts[1].facet;
            address facet = replaced ? _adminFacet : facetCuts[i].facet;
            genesisFacets[i] = GenesisFacet({
                facet: facet,
                isFreezable: facetCuts[i].isFreezable,
                // Explicit, complete routing: the replaced facet's list is read from its own
                // self-description AT BUILD TIME (the generator's job in production) and stored.
                selectors: replaced ? ISelfDescribingFacet(_adminFacet).selectors() : facetCuts[i].selectors,
                codehash: facet.codehash
            });
        }
    }

    /// @dev Builds one hop's release + transition. The release describes the COMPLETE post-hop
    ///      chain state (explicit facet routing, inline pins, carried base-system hashes); the
    ///      transition's facet delta is DERIVED from `(fromRelease, newRelease)` at
    ///      initialization — nothing is hand-authored. When `_newAdminFacet` is zero the target
    ///      release equals the source routing (empty derived delta -> L1-only upgrade with empty
    ///      cuts); otherwise the derived delta replaces the chain's REAL AdminFacet by the given
    ///      implementation, and the hop also carries an L2 force-deployment, making it a full
    ///      minor upgrade.
    function _makeTransition(
        uint256 _oldVersion,
        uint256 _newVersion,
        address _verifier,
        address _fromRelease,
        address _newAdminFacet
    ) internal returns (CTMTransition transition) {
        address release = address(new CTMRelease(_releaseManifest(_newAdminFacet, _verifier)));

        bool hasL2Side = _newAdminFacet != address(0);
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](hasL2Side ? 1 : 0);
        if (hasL2Side) {
            deployments[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: _l2DeploymentType(),
                deployedBytecodeInfo: _l2DeployedBytecodeInfo(),
                newAddress: makeAddr("l2Bridgehub")
            });
        }
        // A nonempty L2 plan MUST carry a delegate target: `L2ComplexUpgrader` always ends with
        // the final delegatecall, so a deployments-only plan (no target) would revert on L2.
        L2UpgradePlan memory l2Plan;
        l2Plan.deployments = deployments;
        l2Plan.factoryDepHashes = new uint256[](0);
        if (hasL2Side) {
            l2Plan.delegateTo = makeAddr("l2UpgradeTarget");
            l2Plan.delegateCalldata = hex"beef";
        }

        transition = new CTMTransition(
            TransitionManifest({
                oldProtocolVersion: _oldVersion,
                newProtocolVersion: _newVersion,
                fromRelease: _fromRelease,
                newRelease: release,
                upgradeEngine: defaultUpgrade,
                upgradeEngineCodehash: defaultUpgrade.codehash,
                oldProtocolVersionDeadline: 1000,
                upgradeTimestamp: 0,
                l2Plan: l2Plan
            })
        );
    }

    function _runHop(CTMTransition _transition) internal {
        vm.startPrank(governor);
        ctmExecutor.applyCTMUpgrade(ICTMTransition(address(_transition)));
        ctmExecutor.upgradeChain(ICTMTransition(address(_transition)), chainId);
        vm.stopPrank();
    }

    function test_registryDrivenUpgrade_v32ThenV33_endToEnd() public {
        // Hop 1 (0.0.0 -> 0.32.0): L1-only registry-driven upgrade — the target release differs
        // from genesis only in the verifier, so the DERIVED facet/hash delta is empty and no L2
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

        // The committed L2 upgrade transaction is exactly the registry-composed one, carrying
        // the VM's upgrade-transaction type (254 for Era, 126 for ZKsyncOS).
        L2CanonicalTransaction memory expectedTx = CTMUpgradeComposer.buildL2UpgradeTx(
            ICTMTransition(address(transitionV33))
        );
        assertEq(expectedTx.txType, _expectedL2UpgradeTxType(), "the upgrade tx must carry the VM's upgrade tx type");
        assertEq(expectedTx.nonce, 33, "upgrade tx nonce must equal the new minor version");
        assertEq(
            IGetters(chainAddress).getL2SystemContractsUpgradeTxHash(),
            keccak256(abi.encode(expectedTx)),
            "the chain must commit the registry-composed L2 upgrade transaction"
        );
    }

    function test_revertWhen_hopReplayed() public {
        _runHop(transitionV32);

        // Replaying the chain upgrade of a completed hop fails the chain's own version check.
        vm.expectRevert(abi.encodeWithSelector(ProtocolIdMismatch.selector, V32, 0));
        vm.prank(governor);
        ctmExecutor.upgradeChain(ICTMTransition(address(transitionV32)), chainId);
    }

    function test_permissionlessUpgradeChainAfterDeadline() public {
        // Governance commits the hop but never executes the chain upgrade. Once the old-version
        // deadline (1000, pinned by the transition) passes, the upgrade is operationally
        // mandatory and ANYONE may execute it — no discretionary inputs remain.
        vm.prank(governor);
        ctmExecutor.applyCTMUpgrade(ICTMTransition(address(transitionV32)));

        vm.warp(1001);
        vm.prank(makeAddr("keeper"));
        ctmExecutor.upgradeChain(ICTMTransition(address(transitionV32)), chainId);

        assertEq(IGetters(chainAddress).getProtocolVersion(), V32, "keeper-executed upgrade must land");
        assertEq(address(IGetters(chainAddress).getVerifier()), verifierV32);
    }

    /// @dev Upgrading is the chain's own decision, so its admin may execute the committed hop at
    ///      any point in the window — a stranger still has to wait for the deadline
    ///      (`test_revertWhen_strangerUpgradesChainBeforeDeadline` in CTMUpgradeExecutor.t.sol).
    function test_chainAdminUpgradesTheirOwnChainBeforeTheDeadline() public {
        vm.prank(governor);
        ctmExecutor.applyCTMUpgrade(ICTMTransition(address(transitionV32)));

        vm.warp(999);
        vm.prank(IGetters(chainAddress).getAdmin());
        ctmExecutor.upgradeChain(ICTMTransition(address(transitionV32)), chainId);

        assertEq(IGetters(chainAddress).getProtocolVersion(), V32, "admin-executed upgrade must land");
    }
}

/// @notice The registry-driven upgrade run against an Era CTM and chain: the chain commits a
///         `SYSTEM_UPGRADE_L2_TX_TYPE` (254) transaction with an Era force-deployment.
contract RegistryDrivenUpgradeEraTest is RegistryDrivenUpgradeTestBase {
    function _deployFixture() internal override {
        deploy();
    }

    function _isZKsyncOSVariant() internal pure override returns (bool) {
        return false;
    }

    function _expectedL2UpgradeTxType() internal pure override returns (uint256) {
        return SYSTEM_UPGRADE_L2_TX_TYPE;
    }

    function _l2DeploymentType() internal pure override returns (IComplexUpgrader.ContractUpgradeType) {
        return IComplexUpgrader.ContractUpgradeType.EraForceDeployment;
    }

    function _l2DeployedBytecodeInfo() internal pure override returns (bytes memory) {
        // For Era this is the abi-encoded bytecode hash of the force-deployed contract.
        return abi.encode(bytes32(uint256(0x0100000000000000000000000000000000000000000000000000000000000001)));
    }

    function _registryGenesisBatchCommitment() internal pure override returns (bytes32) {
        return bytes32(uint256(2));
    }
}

/// @notice The registry-driven upgrade run against a ZKsyncOS CTM and chain: the chain commits
///         a `ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE` (126) transaction with a
///         `ZKsyncOSSystemProxyUpgrade` deployment, and the registry's genesis params carry the
///         `genesisBatchCommitment == 1` that `ZKsyncOSChainTypeManager` enforces.
contract RegistryDrivenUpgradeZKsyncOSTest is ZKsyncOSChainTypeManagerSharedTest, RegistryDrivenUpgradeTestBase {
    function _deployFixture() internal override {
        deployZKsyncOS();
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

    function _l2DeployedBytecodeInfo() internal pure override returns (bytes memory) {
        // For ZKsyncOS this is the abi-encoded (bytecodeHash, bytecodeLength, observableHash)
        // tuple of the new implementation.
        return abi.encode(bytes32(uint256(0xb001)), uint32(64), bytes32(uint256(0xb002)));
    }

    function _registryGenesisBatchCommitment() internal pure override returns (bytes32) {
        // ZKsyncOSChainTypeManager requires the genesis batch commitment to be exactly 1.
        return bytes32(uint256(1));
    }
}
