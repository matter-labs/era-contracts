// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ZKsyncOSChainTypeManagerSharedTest} from "../../state-transition/ChainTypeManager/_ZKsyncOSChainTypeManager_Shared.t.sol";
import {RegistryDrivenUpgradeTestBase} from "./RegistryDrivenUpgrade.t.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {AdminFacet} from "contracts/state-transition/chain-deps/facets/Admin.sol";
import {RollupDAManager} from "contracts/state-transition/data-availability/RollupDAManager.sol";
import {ValidatorTimelock} from "contracts/state-transition/validators/ValidatorTimelock.sol";
import {AcceptingVerifier} from "contracts/dev-contracts/test/AcceptingVerifier.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {
    CTM_CONTRACT_COUNT,
    CTMContract,
    L2_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {
    AuthoredL2Plan,
    PinnedContract,
    ProxyUpgradeRow,
    ReleaseGenesisData,
    ReleaseManifest,
    TransitionManifest
} from "contracts/upgrades/registry/RegistryTypes.sol";

/// @notice Individual-contract upgrades through the registry model, end to end on a real ZKsync OS
///         chain: a facet-only edge, a verifier-only edge and a ValidatorTimelock-only SemVer
///         patch. Each is ONE release (or none) and ONE transition, run through the executor's
///         three stages exactly like a full minor upgrade — and each proves that everything it
///         does not name stays as it was: the other facets, the verifier, the CTM implementation,
///         the L2 side (no transaction is committed) and the release the CTM is on.
/// @dev Departs from the state the base fixture's first hop leaves behind (0.32.0 on the v32
///      release), so every scenario starts from a chain whose routing a REAL release describes.
contract RegistryIndividualUpgradeTest is ZKsyncOSChainTypeManagerSharedTest, RegistryDrivenUpgradeTestBase {
    // keccak256("eip1967.proxy.implementation") - 1
    bytes32 internal constant EIP1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // 0.32.1: the patch edge of a same-release transition.
    uint256 internal constant V32_PATCH_1 = V32 + 1;

    /// @dev Everything an individual upgrade must leave alone, captured before the edge.
    struct UnrelatedState {
        address[] facets;
        address verifier;
        bytes32 ctmImplementationSlot;
        address currentRelease;
    }

    // ── per-VM hooks (the ZKsync OS variant of the base fixture) ──

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

    function _registryGenesisBatchCommitment() internal pure override returns (bytes32) {
        return bytes32(uint256(1));
    }

    // ── scenarios ──

    /// @dev A facet-only edge: the target release differs from the departing one in the AdminFacet
    ///      row alone. The derived facet delta replaces that facet's routing; the L2 table is
    ///      identical, so the release-pair derivation yields no L2 deployment and no delegate is
    ///      needed.
    function test_facetOnlyUpgrade_replacesOneFacetAndNothingElse() public {
        _runHop(transitionV32);
        UnrelatedState memory before = _snapshot();
        address adminV33 = address(new AdminFacet(block.chainid, RollupDAManager(address(0))));
        CTMRelease target = _release(adminV33, before.verifier);
        CTMTransition facetOnly = _transition(V32, V33, transitionV32.newRelease(), address(target), _noRows());
        assertEq(facetOnly.l2Plan().deployments.length, 0, "an unchanged L2 table derives no L2 deployment");

        _runHop(facetOnly);

        assertEq(IGetters(chainAddress).getProtocolVersion(), V33, "the chain crossed the edge");
        assertEq(chainContractAddress.protocolVersion(), V33, "the CTM committed the edge");
        assertEq(IGetters(chainAddress).facetAddress(IAdmin.acceptAdmin.selector), adminV33, "AdminFacet re-pointed");
        _assertUnchangedExceptFacet(before, 1);
        assertEq(chainContractAddress.currentRelease(), address(target), "the CTM moved to the target release");
        assertEq(
            IGetters(chainAddress).getL2SystemContractsUpgradeTxHash(),
            bytes32(0),
            "a facet-only edge commits no L2 transaction"
        );
    }

    /// @dev A verifier-only edge: same facets, same L2 table, a fresh verifier pinned by the
    ///      target release. The derived facet delta and the derived L2 set are both empty; the
    ///      engine installs the verifier from the composed proposal.
    function test_verifierOnlyUpgrade_switchesTheVerifierAndNothingElse() public {
        _runHop(transitionV32);
        UnrelatedState memory before = _snapshot();
        address verifierNext = address(new AcceptingVerifier());
        CTMRelease target = _release(address(0), verifierNext);
        CTMTransition verifierOnly = _transition(V32, V33, transitionV32.newRelease(), address(target), _noRows());
        assertEq(verifierOnly.l2Plan().deployments.length, 0, "an unchanged L2 table derives no L2 deployment");

        _runHop(verifierOnly);

        assertEq(IGetters(chainAddress).getProtocolVersion(), V33, "the chain crossed the edge");
        assertEq(address(IGetters(chainAddress).getVerifier()), verifierNext, "the verifier switched");
        _assertFacetsUnchanged(before);
        assertEq(vm.load(address(chainContractAddress), EIP1967_IMPLEMENTATION_SLOT), before.ctmImplementationSlot);
        assertEq(chainContractAddress.currentRelease(), address(target), "the CTM moved to the target release");
        assertEq(IGetters(chainAddress).getL2SystemContractsUpgradeTxHash(), bytes32(0), "no L2 transaction");
    }

    /// @dev A ValidatorTimelock-only edge: a SemVer PATCH transition that reuses the departing
    ///      release (so no chain state changes: empty facet delta, no L2 side) and carries ONE
    ///      CTM-domain row — the timelock proxy's implementation swap under the executor's bound
    ///      ProxyAdmin. Chains still cross the (empty) edge for the version bump.
    function test_validatorTimelockOnlyPatch_swapsOneProxyAndNothingElse() public {
        _runHop(transitionV32);
        UnrelatedState memory before = _snapshot();
        // The timelock proxy lives under the executor's bound CTM-domain ProxyAdmin, which the
        // executor must own to apply the row (the bootstrap edge hands that admin over).
        ProxyAdmin ctmProxyAdmin = ctmExecutor.CTM_PROXY_ADMIN();
        address implOld = address(new ValidatorTimelock(address(bridgehub)));
        address implNew = address(new ValidatorTimelock(address(bridgehub)));
        TransparentUpgradeableProxy timelock = new TransparentUpgradeableProxy(implOld, address(ctmProxyAdmin), hex"");
        ctmProxyAdmin.transferOwnership(address(ctmExecutor));
        ProxyUpgradeRow[] memory rows = _noRows();
        rows[uint256(CTMContract.ValidatorTimelock)] = ProxyUpgradeRow({
            proxy: address(timelock),
            expectedOldImpl: implOld,
            implNew: PinnedContract({addr: implNew, codehash: implNew.codehash}),
            callInitializeUpgrade: false,
            admin: ProxyAdmin(address(0))
        });
        address release = transitionV32.newRelease();
        CTMTransition timelockOnly = _transition(V32, V32_PATCH_1, release, release, rows);
        assertEq(timelockOnly.l2Plan().deployments.length, 0, "a same-release patch has no L2 side");

        _runHop(timelockOnly);

        assertEq(
            address(uint160(uint256(vm.load(address(timelock), EIP1967_IMPLEMENTATION_SLOT)))),
            implNew,
            "the timelock proxy points at the new implementation"
        );
        assertEq(IGetters(chainAddress).getProtocolVersion(), V32_PATCH_1, "the chain crossed the patch edge");
        assertEq(chainContractAddress.protocolVersion(), V32_PATCH_1, "the CTM committed the patch edge");
        _assertFacetsUnchanged(before);
        assertEq(address(IGetters(chainAddress).getVerifier()), before.verifier, "the verifier is untouched");
        assertEq(vm.load(address(chainContractAddress), EIP1967_IMPLEMENTATION_SLOT), before.ctmImplementationSlot);
        assertEq(chainContractAddress.currentRelease(), before.currentRelease, "a patch keeps the release");
        assertEq(IGetters(chainAddress).getL2SystemContractsUpgradeTxHash(), bytes32(0), "no L2 transaction");
    }

    // ── helpers ──

    function _snapshot() internal view returns (UnrelatedState memory state) {
        state.facets = new address[](facetCuts.length);
        for (uint256 i = 0; i < facetCuts.length; ++i) {
            state.facets[i] = IGetters(chainAddress).facetAddress(facetCuts[i].selectors[0]);
        }
        state.verifier = address(IGetters(chainAddress).getVerifier());
        state.ctmImplementationSlot = vm.load(address(chainContractAddress), EIP1967_IMPLEMENTATION_SLOT);
        state.currentRelease = chainContractAddress.currentRelease();
    }

    function _assertFacetsUnchanged(UnrelatedState memory _before) internal view {
        _assertUnchangedExceptFacet(_before, type(uint256).max);
    }

    /// @dev Every facet but `_replacedIndex` (the fixture's facet-cut index) still routes where it
    ///      did; the verifier and the CTM implementation too.
    function _assertUnchangedExceptFacet(UnrelatedState memory _before, uint256 _replacedIndex) internal view {
        for (uint256 i = 0; i < facetCuts.length; ++i) {
            if (i == _replacedIndex) {
                continue;
            }
            assertEq(
                IGetters(chainAddress).facetAddress(facetCuts[i].selectors[0]),
                _before.facets[i],
                "an unrelated facet moved"
            );
        }
        if (_replacedIndex != type(uint256).max) {
            assertEq(address(IGetters(chainAddress).getVerifier()), _before.verifier, "the verifier is untouched");
            assertEq(
                vm.load(address(chainContractAddress), EIP1967_IMPLEMENTATION_SLOT),
                _before.ctmImplementationSlot,
                "the CTM implementation is untouched"
            );
        }
    }

    /// @dev A release describing the chain's routing with the AdminFacet swapped for `_adminFacet`
    ///      when nonzero, the given verifier, and the fixture's (empty) L2 table.
    function _release(address _adminFacet, address _verifier) internal returns (CTMRelease) {
        return
            new CTMRelease(
                ReleaseManifest({
                    diamondInit: PinnedContract({addr: diamondInit, codehash: diamondInit.codehash}),
                    verifier: PinnedContract({addr: _verifier, codehash: _verifier.codehash}),
                    genesisUpgrade: PinnedContract({addr: genesisUpgradeAddr, codehash: genesisUpgradeAddr.codehash}),
                    genesisFacets: _releaseFacets(_adminFacet),
                    genesis: ReleaseGenesisData({
                        fixedForceDeploymentsData: hex"f1f2",
                        genesisBatchHash: bytes32(uint256(1)),
                        genesisBatchCommitment: _registryGenesisBatchCommitment(),
                        genesisIndexRepeatedStorageChanges: 54
                    }),
                    l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT)
                })
            );
    }

    function _noRows() internal pure returns (ProxyUpgradeRow[] memory) {
        return new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
    }

    /// @dev An L1-only transition (no authored L2 remainder) over `_rows`, with its own timer.
    function _transition(
        uint256 _oldVersion,
        uint256 _newVersion,
        address _fromRelease,
        address _newRelease,
        ProxyUpgradeRow[] memory _rows
    ) internal returns (CTMTransition) {
        address upgradeTimer = address(new GovernanceUpgradeTimer(0, 0, address(ctmExecutor), governor));
        return
            new CTMTransition(
                TransitionManifest({
                    oldProtocolVersion: _oldVersion,
                    newProtocolVersion: _newVersion,
                    fromRelease: _fromRelease,
                    newRelease: _newRelease,
                    upgradeEngine: PinnedContract({addr: defaultUpgrade, codehash: defaultUpgrade.codehash}),
                    proxyUpgrades: _rows,
                    oldProtocolVersionDeadline: 1000,
                    upgradeTimestamp: 0,
                    l2Plan: AuthoredL2Plan({
                        extraDeployments: new IComplexUpgrader.UniversalContractUpgradeInfo[](0),
                        delegateTo: address(0),
                        delegateComposer: PinnedContract({addr: address(0), codehash: bytes32(0)}),
                        factoryDepHashes: new uint256[](0)
                    }),
                    coreRegistry: PinnedContract({addr: address(0), codehash: bytes32(0)}),
                    upgradeTimer: PinnedContract({addr: upgradeTimer, codehash: upgradeTimer.codehash})
                })
            );
    }
}
