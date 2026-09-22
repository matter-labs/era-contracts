// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseZkSyncUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {BootstrapUpgrade} from "contracts/upgrades/BootstrapUpgrade.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {L2CanonicalTransactionLib} from "contracts/state-transition/libraries/L2CanonicalTransactionLib.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {NotAllBatchesExecuted} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {TimeNotReached} from "contracts/common/L1ContractErrors.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";
import {RegistryObjectsFixture} from "./_SharedRegistryObjects.t.sol";

contract DummyBootstrapUpgrade is BootstrapUpgrade, BaseUpgradeUtils {}

/// @notice The bootstrap edge on the chain side (`upgradeFromBootstrap`) against a REAL
///         `RegistryBootstrapMigration`: the engine is handed nothing but the migration address and
///         must read everything off it — the release whose routing and verifier it reinstalls, the
///         version edge, the schedule and the L2 plan. The engine under test plays the chain
///         diamond (called directly, so its own diamond storage is the chain's); the migration's
///         CTM-side authorities are stand-ins the engine never touches.
contract BootstrapUpgradeTest is BaseUpgrade, RegistryObjectsFixture {
    DummyBootstrapUpgrade internal engine;
    CTMRelease internal genesisRelease;
    address internal legacyVerifier;
    address internal mockBridgehub = makeAddr("mockBridgehub");

    bytes internal constant DELEGATE_CALLDATA = hex"beef";

    function setUp() public {
        _prepareUpgrade();
        _setUpRegistryObjects(DELEGATE_CALLDATA);
        _mockEcosystemForComposer(mockBridgehub, ctmDeployerStub);
        // The migration reads the ecosystem's Bridgehub off its CTM; the stand-in CTM answers with
        // the chain's.
        vm.mockCall(ctmStub, abi.encodeCall(IChainTypeManager.BRIDGE_HUB, ()), abi.encode(mockBridgehub));
        // A release's `validate()` rejects a codeless verifier, so the one it installs has code.
        verifier = _deployedStub("releaseVerifier");
        genesisRelease = _release(_arrivingFacets(), verifier, protocolVersion);
        engine = new DummyBootstrapUpgrade();
        engine.setPriorityTxMaxGasLimit(1 ether);
        engine.setPriorityTxMaxPubdata(1000000);
        engine.setBridgehub(mockBridgehub);
        engine.setChainId(ETH_CHAIN_ID);
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
        legacyVerifier = _deployedStub("legacyVerifier");
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

        // The object's own read of the same transaction, for this chain, agrees.
        assertEq(
            keccak256(abi.encode(migration.l2UpgradeTx(ETH_CHAIN_ID))),
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

    /// @dev The engine holds no release of its own: the one it installs is the one the migration
    ///      it is handed names. That is what lets a lagging chain cross the edge on its OWN
    ///      committed migration after the CTM has moved on — the same engine deployment serves both.
    function test_upgradeFromBootstrap_installsTheReleaseTheMigrationNames() public {
        address otherVerifier = _deployedStub("otherVerifier");
        CTMRelease otherRelease = _release(_arrivingFacets(), otherVerifier, protocolVersion);
        RegistryBootstrapMigration migration = _migration(otherRelease, 0, address(engine), false);

        engine.upgradeFromBootstrap(address(migration));

        assertEq(engine.getVerifier(), otherVerifier, "the verifier comes off the release the migration names");
        assertTrue(otherVerifier != verifier, "the two releases really do install different verifiers");
        assertEq(engine.facetAddress(SEL_ARRIVING), facetArriving, "that release's routing is installed");
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

    /// @dev The bootstrap edge installs the release's verifier like every transition after it, so
    ///      the outstanding-batches precondition gates it too.
    function test_revertWhen_upgradeFromBootstrap_aCommittedBatchIsNotExecuted() public {
        engine.setBatchCounters(8, 7);
        RegistryBootstrapMigration migration = _migration(genesisRelease, 0, address(engine), false);

        vm.expectRevert(NotAllBatchesExecuted.selector);
        engine.upgradeFromBootstrap(address(migration));

        engine.setBatchCounters(8, 8);
        engine.upgradeFromBootstrap(address(migration));
        assertEq(engine.getProtocolVersion(), protocolVersion);
        assertEq(engine.getVerifier(), verifier);
        assertEq(engine.facetAddress(SEL_ARRIVING), facetArriving, "the reinstall runs once the batches are executed");
    }

    /// @dev The bootstrap edge composes its L2 leg the same one-pass, per-chain way transitions
    ///      do (the REAL v34 composer over the mocked ecosystem — see the shared fixture): what the
    ///      chain commits is what the migration serves FOR THAT CHAIN, and another chain of the
    ///      ecosystem is served another transaction.
    function test_upgradeFromBootstrap_commitsTheTransactionComposedForThisChain() public {
        RegistryBootstrapMigration migration = new RegistryBootstrapMigration(
            _bootstrapManifest(genesisRelease, 0, 0, address(engine), _v34Plan())
        );
        L2CanonicalTransaction memory expectedTx = _expectedV34L2Tx(migration.l2Plan(), protocolVersion, ETH_CHAIN_ID);

        engine.upgradeFromBootstrap(address(migration));

        bytes32 recorded = engine.getL2SystemContractsUpgradeTxHash();
        assertEq(recorded, keccak256(abi.encode(expectedTx)), "the chain commits its own composition");
        L2CanonicalTransaction memory served = migration.l2UpgradeTx(ETH_CHAIN_ID);
        assertEq(keccak256(abi.encode(served)), recorded, "the migration serves what this chain committed");
        assertEq(_perChainData(served.data).baseTokenBridgingData.assetId, ETH_BASE_TOKEN_ASSET_ID);

        L2CanonicalTransaction memory forOtherChain = migration.l2UpgradeTx(ERC20_CHAIN_ID);
        assertTrue(keccak256(abi.encode(forOtherChain)) != recorded, "another chain is served its own transaction");
        assertEq(_perChainData(forOtherChain.data).baseTokenBridgingData.assetId, ERC20_BASE_TOKEN_ASSET_ID);
    }
}
