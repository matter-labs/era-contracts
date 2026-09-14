// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {MockSelfDescribingFacet} from "contracts/dev-contracts/test/MockSelfDescribingFacet.sol";
import {FixedDelegateCalldataComposer} from "contracts/dev-contracts/FixedDelegateCalldataComposer.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {L2CanonicalTransactionLib} from "contracts/state-transition/libraries/L2CanonicalTransactionLib.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {
    PRIORITY_TX_MAX_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    SYSTEM_UPGRADE_L2_TX_TYPE,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE
} from "contracts/common/Config.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SEMVER_MINOR_OFFSET} from "contracts/common/libraries/SemVer.sol";
import {
    AuthoredL2Plan,
    BootstrapManifest,
    GenesisFacet,
    L2UpgradePlan,
    PinnedContract,
    ProxyUpgradeRow,
    ReleaseGenesisData,
    ReleaseManifest,
    TransitionManifest
} from "contracts/upgrades/registry/RegistryTypes.sol";
import {
    CTM_CONTRACT_COUNT,
    CTMContract,
    L2_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {L2PlanFixtures} from "foundry-test/l1/unit/concrete/upgrades/registry/L2PlanFixtures.sol";

/// @notice Real, minimal registry objects for the upgrade-engine unit tests: two releases that
///         differ in one facet and their verifier, the transition between them, and a bootstrap
///         manifest toward one of them. Everything an engine reads at execution is a real
///         write-once object; only the CTM-side authorities a manifest has to name (CTM, admins,
///         executors, timer) are labelled stand-ins the engine never touches.
abstract contract RegistryObjectsFixture is Test {
    // Real self-describing facets — the routing the registry objects read and the engines apply.
    address internal facetShared; // in both releases
    address internal facetDeparting; // only in the departing release
    address internal facetArriving; // only in the target release
    /// @dev A real DiamondInit: the composer reads VM identity off its `IS_ZKSYNC_OS` immutable.
    address internal diamondInit;
    address internal genesisUpgradeStub;
    address internal upgradeTimerStub;
    address internal ctmStub;
    /// @dev Returns `fixtureDelegateCalldata` regardless of its inputs — the stand-in for a
    ///      version-specific composer, so plans can pin a real composer without an L2 migration.
    FixedDelegateCalldataComposer internal delegateComposer;
    bytes internal fixtureDelegateCalldata;
    bool internal fixtureIsZKsyncOS;

    bytes4 internal constant SEL_SHARED_A = bytes4(uint32(0x11));
    bytes4 internal constant SEL_SHARED_B = bytes4(uint32(0x12));
    bytes4 internal constant SEL_DEPARTING = bytes4(uint32(0x21));
    bytes4 internal constant SEL_ARRIVING = bytes4(uint32(0x31));

    /// @dev Dummy EVM bytecode standing in for the authored L2 upgrade delegate (see {L2PlanFixtures}).
    bytes internal constant DELEGATE_CODE = hex"aa01";

    function _setUpRegistryObjects(bool _isZKsyncOS, bytes memory _delegateCalldata) internal {
        fixtureIsZKsyncOS = _isZKsyncOS;
        fixtureDelegateCalldata = _delegateCalldata;
        facetShared = address(new MockSelfDescribingFacet(_selectors2(SEL_SHARED_A, SEL_SHARED_B)));
        facetDeparting = address(new MockSelfDescribingFacet(_selectors1(SEL_DEPARTING)));
        facetArriving = address(new MockSelfDescribingFacet(_selectors1(SEL_ARRIVING)));
        diamondInit = address(new DiamondInit(_isZKsyncOS));
        genesisUpgradeStub = _pinned("genesisUpgrade");
        upgradeTimerStub = _pinned("upgradeTimer");
        ctmStub = makeAddr("ctm");
        delegateComposer = new FixedDelegateCalldataComposer(_delegateCalldata);
    }

    // ─────────────────────────────── objects ───────────────────────────────

    /// @dev A release pinning `_facets` (all non-freezable), `_verifier`, the fixture's DiamondInit
    ///      and an empty L2 table.
    function _release(address[] memory _facets, address _verifier) internal returns (CTMRelease) {
        GenesisFacet[] memory rows = new GenesisFacet[](_facets.length);
        for (uint256 i = 0; i < _facets.length; ++i) {
            rows[i] = GenesisFacet({facet: _pin(_facets[i]), isFreezable: false});
        }
        return
            new CTMRelease(
                ReleaseManifest({
                    diamondInit: _pin(diamondInit),
                    verifier: _pin(_verifier),
                    genesisUpgrade: _pin(genesisUpgradeStub),
                    genesisFacets: rows,
                    genesis: ReleaseGenesisData({
                        fixedForceDeploymentsData: hex"f1f2",
                        genesisBatchHash: bytes32(uint256(1)),
                        genesisBatchCommitment: bytes32(uint256(1)),
                        genesisIndexRepeatedStorageChanges: 54
                    }),
                    l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT)
                })
            );
    }

    function _departingFacets() internal view returns (address[] memory facets) {
        facets = new address[](2);
        facets[0] = facetShared;
        facets[1] = facetDeparting;
    }

    function _arrivingFacets() internal view returns (address[] memory facets) {
        facets = new address[](2);
        facets[0] = facetShared;
        facets[1] = facetArriving;
    }

    /// @dev No authored L2 side: an L1-only edge.
    function _emptyPlan() internal pure returns (AuthoredL2Plan memory) {
        return
            AuthoredL2Plan({
                extraDeployments: new IComplexUpgrader.UniversalContractUpgradeInfo[](0),
                delegateTo: address(0),
                delegateComposer: _noPin(),
                factoryDepHashes: new uint256[](0)
            });
    }

    /// @dev The minimal well-formed authored L2 side: the delegate's own Unsafe deployment at its
    ///      bytecode-derived address, the pinned composer defining its calldata, the delegate's
    ///      bytecode as the one factory dependency.
    function _delegatePlan() internal view returns (AuthoredL2Plan memory) {
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory extras = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        extras[0] = L2PlanFixtures.unsafeDeployment(DELEGATE_CODE);
        return
            AuthoredL2Plan({
                extraDeployments: extras,
                delegateTo: extras[0].newAddress,
                delegateComposer: _pin(address(delegateComposer)),
                factoryDepHashes: L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(DELEGATE_CODE))
            });
    }

    function _transition(
        CTMRelease _fromRelease,
        CTMRelease _newRelease,
        uint256 _oldProtocolVersion,
        uint256 _newProtocolVersion,
        uint256 _upgradeTimestamp,
        address _upgradeEngine,
        AuthoredL2Plan memory _plan
    ) internal returns (CTMTransition) {
        return
            new CTMTransition(
                TransitionManifest({
                    oldProtocolVersion: _oldProtocolVersion,
                    newProtocolVersion: _newProtocolVersion,
                    fromRelease: address(_fromRelease),
                    newRelease: address(_newRelease),
                    upgradeEngine: _pin(_upgradeEngine),
                    proxyUpgrades: new ProxyUpgradeRow[](CTM_CONTRACT_COUNT),
                    oldProtocolVersionDeadline: type(uint256).max,
                    upgradeTimestamp: _upgradeTimestamp,
                    l2Plan: _plan,
                    coreRegistry: _noPin(),
                    upgradeTimer: _pin(upgradeTimerStub)
                })
            );
    }

    /// @dev A bootstrap manifest toward `_release`. The CTM-side authorities are labelled
    ///      stand-ins: the engine reads only the version edge, the schedule, the release and the
    ///      L2 plan; the one participating proxy row exists because the object refuses an edge
    ///      without implementation swaps.
    function _bootstrapManifest(
        CTMRelease _release,
        uint256 _oldProtocolVersion,
        uint256 _newProtocolVersion,
        uint256 _upgradeTimestamp,
        address _upgradeEngine,
        AuthoredL2Plan memory _plan
    ) internal returns (BootstrapManifest memory) {
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        rows[uint256(CTMContract.ChainTypeManager)] = ProxyUpgradeRow({
            proxy: makeAddr("ctmProxy"),
            expectedOldImpl: makeAddr("ctmImplOld"),
            implNew: _pin(_pinned("ctmImplNew")),
            callInitializeUpgrade: false,
            admin: ProxyAdmin(address(0))
        });
        return
            BootstrapManifest({
                ctm: ctmStub,
                expectedProtocolVersion: _oldProtocolVersion,
                ctmProxyAdmin: ProxyAdmin(makeAddr("ctmProxyAdmin")),
                proxyUpgrades: rows,
                currentRelease: _pin(address(_release)),
                newProtocolVersion: _newProtocolVersion,
                oldProtocolVersionDeadline: type(uint256).max,
                upgradeEngine: _pin(_upgradeEngine),
                l2Plan: _plan,
                upgradeTimestamp: _upgradeTimestamp,
                ctmExecutor: _pin(_pinned("ctmExecutor")),
                ctmExecutorOwner: makeAddr("governor"),
                ecosystemExecutor: makeAddr("ecosystemExecutor"),
                upgradeTimer: _pin(upgradeTimerStub)
            });
    }

    // ─────────────────────────────── expectations ───────────────────────────────

    /// @dev The transaction the composer builds for a FINAL plan at `_newProtocolVersion`,
    ///      assembled from the constants it reads rather than through the library under test, so
    ///      equality against it is a real check of the composition.
    function _expectedL2Tx(
        L2UpgradePlan memory _plan,
        uint256 _newProtocolVersion
    ) internal view returns (L2CanonicalTransaction memory transaction) {
        transaction = L2CanonicalTransactionLib.emptyL2CanonicalTransaction();
        transaction.txType = fixtureIsZKsyncOS ? ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE : SYSTEM_UPGRADE_L2_TX_TYPE;
        transaction.from = uint256(uint160(L2_FORCE_DEPLOYER_ADDR));
        transaction.to = uint256(uint160(L2_COMPLEX_UPGRADER_ADDR));
        transaction.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        transaction.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        transaction.nonce = _newProtocolVersion >> SEMVER_MINOR_OFFSET;
        transaction.data = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (_plan.deployments, _plan.delegateTo, fixtureDelegateCalldata)
        );
        transaction.factoryDeps = _plan.factoryDepHashes;
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    /// @dev Deploys a distinct-bytecode stand-in at a labelled address so EXTCODEHASH pins are
    ///      real (an empty address would pin the zero hash).
    function _pinned(string memory _name) internal returns (address addr) {
        addr = makeAddr(_name);
        vm.etch(addr, bytes.concat(hex"00", bytes(_name)));
    }

    function _pin(address _addr) internal view returns (PinnedContract memory) {
        return PinnedContract({addr: _addr, codehash: _addr.codehash});
    }

    function _noPin() internal pure returns (PinnedContract memory) {
        return PinnedContract({addr: address(0), codehash: bytes32(0)});
    }

    function _selectors1(bytes4 _a) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _a;
    }

    function _selectors2(bytes4 _a, bytes4 _b) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = _a;
        selectors[1] = _b;
    }
}
