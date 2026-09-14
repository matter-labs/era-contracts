// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseZkSyncUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {BootstrapUpgradeZKsyncOS} from "contracts/upgrades/BootstrapUpgradeZKsyncOS.sol";
import {BootstrapUpgradeDev} from "contracts/dev-contracts/BootstrapUpgradeDev.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {L2CanonicalTransactionLib} from "contracts/state-transition/libraries/L2CanonicalTransactionLib.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {BootstrapEngineReleaseMismatch} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {NotAllBatchesExecuted} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {TimeNotReached} from "contracts/common/L1ContractErrors.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";
import {RegistryObjectsFixture} from "./_SharedRegistryObjects.t.sol";

contract DummyBootstrapUpgradeDev is BootstrapUpgradeDev, BaseUpgradeUtils {
    constructor(ICTMRelease _genesisRelease) BootstrapUpgradeDev(_genesisRelease) {}
}

contract DummyBootstrapUpgradeZKsyncOS is BootstrapUpgradeZKsyncOS, BaseUpgradeUtils {
    constructor(ICTMRelease _genesisRelease) BootstrapUpgradeZKsyncOS(_genesisRelease) {}
}

/// @notice The bootstrap edge on the chain side (`upgradeFromBootstrap`) against a REAL
///         `RegistryBootstrapMigration`: the engine is handed nothing but the migration address and
///         must reinstall the routing from the release it pins, then read the version edge, the
///         schedule and the L2 plan from the migration. The engine under test plays the chain
///         diamond (called directly, so its own diamond storage is the chain's); the migration's
///         CTM-side authorities are stand-ins the engine never touches.
contract BootstrapUpgradeTest is BaseUpgrade, RegistryObjectsFixture {
    DummyBootstrapUpgradeDev internal engine;
    CTMRelease internal genesisRelease;
    address internal legacyVerifier;
    address internal mockBridgehub = makeAddr("mockBridgehub");

    bytes internal constant DELEGATE_CALLDATA = hex"beef";

    function setUp() public {
        _prepareUpgrade();
        _setUpRegistryObjects(true, DELEGATE_CALLDATA);
        // A release pins its verifier by codehash, so the one it installs has code.
        verifier = _pinned("releaseVerifier");
        genesisRelease = _release(_arrivingFacets(), verifier);
        engine = new DummyBootstrapUpgradeDev(genesisRelease);
        engine.setPriorityTxMaxGasLimit(1 ether);
        engine.setPriorityTxMaxPubdata(1000000);
        engine.setBridgehub(mockBridgehub);
        engine.setZKsyncOS(true);

        // The departing, pre-registry chain: routing no release knows, straight in diamond storage,
        // and a verifier the release does not pin.
        Diamond.FacetCut[] memory legacy = new Diamond.FacetCut[](1);
        legacy[0] = Diamond.FacetCut({
            facet: facetDeparting,
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: _selectors1(SEL_DEPARTING)
        });
        engine.applyFacetCuts(legacy);
        legacyVerifier = _pinned("legacyVerifier");
        engine.setVerifier(legacyVerifier);
    }

    function _migration(
        CTMRelease _release,
        uint256 _upgradeTimestamp,
        address _engine,
        bool _withL2Side
    ) internal returns (RegistryBootstrapMigration) {
        return
            new RegistryBootstrapMigration(
                _bootstrapManifest(
                    _release,
                    0,
                    protocolVersion,
                    _upgradeTimestamp,
                    _engine,
                    _withL2Side ? _delegatePlan() : _emptyPlan()
                )
            );
    }

    function test_upgradeFromBootstrap_reinstallsTheRoutingAndAppliesTheEdge() public {
        RegistryBootstrapMigration migration = _migration(genesisRelease, 0, address(engine), true);
        L2CanonicalTransaction memory expectedTx = _expectedL2Tx(migration.l2Plan(), protocolVersion);
        bytes32 expectedHash = keccak256(abi.encode(expectedTx));

        vm.expectEmit(address(engine));
        emit BaseZkSyncUpgrade.NewProtocolVersion(0, protocolVersion);
        vm.expectEmit(address(engine));
        emit BaseZkSyncUpgrade.NewVerifier(legacyVerifier, verifier);
        vm.expectEmit(address(engine));
        emit BaseZkSyncUpgrade.UpgradeComplete(protocolVersion, expectedHash, expectedTx);
        bytes32 result = engine.upgradeFromBootstrap(address(migration));

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE, "the diamond-init success value");
        assertEq(engine.getProtocolVersion(), protocolVersion, "the version edge comes off the migration");
        assertEq(engine.getVerifier(), verifier, "the verifier comes off the pinned genesis release");
        assertEq(engine.getL2SystemContractsUpgradeTxHash(), expectedHash, "the composed transaction is committed");
        // The full reinstall: the departing routing is gone, the release's routing is installed.
        assertEq(engine.facetAddress(SEL_DEPARTING), address(0), "the departing routing is removed");
        assertEq(engine.facetAddress(SEL_SHARED_A), facetShared, "the release's facets are installed");
        assertEq(engine.facetAddress(SEL_ARRIVING), facetArriving, "the release's facets are installed");

        // The object's own read of the same transaction agrees (its Bridgehub comes off the CTM;
        // the stand-in CTM answers with the chain's).
        vm.mockCall(ctmStub, abi.encodeCall(IChainTypeManager.BRIDGE_HUB, ()), abi.encode(mockBridgehub));
        assertEq(
            keccak256(abi.encode(migration.l2UpgradeTx())),
            expectedHash,
            "the migration serves what the chain committed"
        );
    }

    function test_upgradeFromBootstrap_l1OnlyEdgeSetsNoL2Transaction() public {
        RegistryBootstrapMigration migration = _migration(genesisRelease, 0, address(engine), false);

        vm.expectEmit(address(engine));
        emit BaseZkSyncUpgrade.UpgradeComplete(
            protocolVersion,
            bytes32(0),
            L2CanonicalTransactionLib.emptyL2CanonicalTransaction()
        );
        engine.upgradeFromBootstrap(address(migration));

        assertEq(engine.getL2SystemContractsUpgradeTxHash(), bytes32(0), "no L2 transaction on an L1-only edge");
        assertEq(engine.getProtocolVersion(), protocolVersion);
        assertEq(engine.getVerifier(), verifier);
        assertEq(engine.facetAddress(SEL_ARRIVING), facetArriving, "the reinstall happens on an L1-only edge too");
    }

    /// @dev The manifest pins the engine and the release as two rows; an engine whose immutable
    ///      names another release refuses the pair rather than installing one release's facets and
    ///      verifier on chains the CTM records as running another.
    function test_revertWhen_upgradeFromBootstrap_migrationPinsAnotherRelease() public {
        CTMRelease otherRelease = _release(_arrivingFacets(), _pinned("otherVerifier"));
        RegistryBootstrapMigration migration = _migration(otherRelease, 0, address(engine), false);

        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapEngineReleaseMismatch.selector,
                address(otherRelease),
                address(genesisRelease)
            )
        );
        engine.upgradeFromBootstrap(address(migration));
    }

    function test_revertWhen_upgradeFromBootstrap_beforeTheSchedule() public {
        uint256 scheduled = block.timestamp + 1 days;
        RegistryBootstrapMigration migration = _migration(genesisRelease, scheduled, address(engine), false);

        vm.expectRevert(abi.encodeWithSelector(TimeNotReached.selector, scheduled, block.timestamp));
        engine.upgradeFromBootstrap(address(migration));

        vm.warp(scheduled);
        engine.upgradeFromBootstrap(address(migration));
        assertEq(engine.getProtocolVersion(), protocolVersion);
    }

    /// @dev The production engine inherits the bootstrap entrypoint AND the ZKsync OS storage
    ///      part: the outstanding-batches precondition must gate the bootstrap edge too.
    function test_zksyncOSEngine_requiresEveryCommittedBatchExecuted() public {
        DummyBootstrapUpgradeZKsyncOS osEngine = new DummyBootstrapUpgradeZKsyncOS(genesisRelease);
        osEngine.setBatchCounters(8, 7);
        RegistryBootstrapMigration migration = _migration(genesisRelease, 0, address(osEngine), false);

        vm.expectRevert(NotAllBatchesExecuted.selector);
        osEngine.upgradeFromBootstrap(address(migration));

        osEngine.setBatchCounters(8, 8);
        osEngine.upgradeFromBootstrap(address(migration));
        assertEq(osEngine.getProtocolVersion(), protocolVersion);
        assertEq(osEngine.getVerifier(), verifier);
        assertEq(osEngine.facetAddress(SEL_ARRIVING), facetArriving, "the reinstall runs on the production engine");
    }
}
