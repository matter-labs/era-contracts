// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseZkSyncUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ReleaseFacetReader} from "contracts/upgrades/registry/libraries/ReleaseFacetReader.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {L2CanonicalTransactionLib} from "contracts/state-transition/libraries/L2CanonicalTransactionLib.sol";
import {ZKChainSpecificForceDeploymentsData} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {PreviousUpgradeNotFinalized} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {NotAllBatchesExecuted} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {TimeNotReached} from "contracts/common/L1ContractErrors.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";
import {RegistryObjectsFixture} from "./_SharedRegistryObjects.t.sol";

contract DummyDefaultUpgrade is DefaultUpgrade, BaseUpgradeUtils {}

/// @notice `DefaultUpgrade.upgradeFromTransition` against REAL write-once objects: the engine is
///         handed nothing but the transition address and must read the derived facet cuts, the
///         version edge and schedule, the TARGET release's verifier and the L2 plan from it, and
///         compose the L2 protocol upgrade transaction for THIS chain in one pass. The engine
///         under test plays the chain diamond (it is called directly, so its own diamond storage
///         is the chain's). The same path through a real CTM, executor and chain proxy is covered
///         by RegistryDrivenUpgrade.t.sol.
contract DefaultUpgradeTest is BaseUpgrade, RegistryObjectsFixture {
    DummyDefaultUpgrade internal engine;
    CTMRelease internal fromRelease;
    CTMRelease internal newRelease;
    address internal fromVerifier;
    address internal newVerifier;
    address internal mockBridgehub = makeAddr("mockBridgehub");

    bytes internal constant DELEGATE_CALLDATA = hex"beef";

    function setUp() public {
        engine = new DummyDefaultUpgrade();
        _prepareUpgrade();
        engine.setPriorityTxMaxGasLimit(1 ether);
        engine.setPriorityTxMaxPubdata(1000000);
        engine.setBridgehub(mockBridgehub);
        engine.setChainId(ETH_CHAIN_ID);
        // The composed transaction carries the ZKsync OS upgrade type, which the chain accepts
        // only when it runs ZKsync OS itself.
        engine.setZKsyncOS(true);

        _setUpRegistryObjects(DELEGATE_CALLDATA);
        _mockEcosystemForComposer(mockBridgehub, ctmDeployerStub);
        fromVerifier = _pinned("fromVerifier");
        newVerifier = _pinned("newVerifier");
        fromRelease = _release(_departingFacets(), fromVerifier);
        newRelease = _release(_arrivingFacets(), newVerifier);

        // The chain under test runs the departing release: its routing installed, its verifier live.
        engine.applyFacetCuts(ReleaseFacetReader.newChainInstallations(ICTMRelease(address(fromRelease))));
        engine.setVerifier(fromVerifier);
    }

    function _defaultTransition(uint256 _upgradeTimestamp) internal returns (CTMTransition) {
        return
            _transition(
                fromRelease,
                newRelease,
                0,
                protocolVersion,
                _upgradeTimestamp,
                address(engine),
                _delegatePlan()
            );
    }

    /// @dev The same hop with the REAL v34 composer pinned (see the shared fixture).
    function _v34Transition() internal returns (CTMTransition) {
        return _transition(fromRelease, newRelease, 0, protocolVersion, 0, address(engine), _v34Plan());
    }

    function test_upgradeFromTransition_appliesTheCommittedTransition() public {
        CTMTransition transition = _defaultTransition(0);
        L2CanonicalTransaction memory expectedTx = _expectedL2Tx(transition.l2Plan(), protocolVersion);
        bytes32 expectedHash = keccak256(abi.encode(expectedTx));

        vm.expectEmit(address(engine));
        emit BaseZkSyncUpgrade.NewProtocolVersion(0, protocolVersion);
        vm.expectEmit(address(engine));
        emit BaseZkSyncUpgrade.NewVerifier(fromVerifier, newVerifier);
        vm.expectEmit(address(engine));
        emit BaseZkSyncUpgrade.UpgradeComplete(protocolVersion, expectedHash, expectedTx);
        bytes32 result = engine.upgradeFromTransition(address(transition));

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE, "the diamond-init success value");
        assertEq(engine.getProtocolVersion(), protocolVersion, "the version edge comes off the transition");
        assertEq(engine.getVerifier(), newVerifier, "the verifier comes off the TARGET release");
        assertEq(engine.getL2SystemContractsUpgradeTxHash(), expectedHash, "the composed transaction is committed");
        // The DERIVED delta, applied verbatim: the departing facet's selector is gone, the arriving
        // facet's is routed, the shared facet is untouched.
        assertEq(engine.facetAddress(SEL_DEPARTING), address(0), "the departing facet is removed");
        assertEq(engine.facetAddress(SEL_ARRIVING), facetArriving, "the arriving facet is installed");
        assertEq(engine.facetAddress(SEL_SHARED_A), facetShared, "the shared facet is untouched");
    }

    /// @dev A lagging chain: its CTM has already moved on to a later release, but the chain
    ///      executes the transition committed for ITS edge, whose target release names the
    ///      verifier. The mocked CTM is a tripwire — the engine must never ask it.
    function test_upgradeFromTransition_readsTheTargetReleaseNotTheCTMsLiveOne() public {
        address ctm = makeAddr("chainTypeManager");
        engine.setChainTypeManager(ctm);
        address laterVerifier = _pinned("laterVerifier");
        CTMRelease laterRelease = _release(_arrivingFacets(), laterVerifier);
        vm.mockCall(ctm, abi.encodeCall(IChainTypeManager.currentRelease, ()), abi.encode(address(laterRelease)));

        engine.upgradeFromTransition(address(_defaultTransition(0)));

        assertEq(engine.getVerifier(), newVerifier, "the transition's target release wins");
        assertTrue(engine.getVerifier() != laterVerifier, "the CTM's live release must not leak in");
    }

    /// @dev A verifier-only hop: same facets on both releases, no authored L2 side. The derived
    ///      cuts are empty and the composer yields the all-zero transaction the engine skips.
    function test_upgradeFromTransition_l1OnlyTransitionSetsNoL2Transaction() public {
        CTMRelease verifierOnly = _release(_departingFacets(), newVerifier);
        CTMTransition transition = _transition(
            fromRelease,
            verifierOnly,
            0,
            protocolVersion,
            0,
            address(engine),
            _emptyPlan()
        );

        vm.expectEmit(address(engine));
        emit BaseZkSyncUpgrade.UpgradeComplete(
            protocolVersion,
            bytes32(0),
            L2CanonicalTransactionLib.emptyL2CanonicalTransaction()
        );
        engine.upgradeFromTransition(address(transition));

        assertEq(engine.getL2SystemContractsUpgradeTxHash(), bytes32(0), "no L2 transaction on an L1-only hop");
        assertEq(engine.getVerifier(), newVerifier);
        assertEq(engine.getProtocolVersion(), protocolVersion);
        assertEq(engine.facetAddress(SEL_DEPARTING), facetDeparting, "no facet change on a verifier-only hop");
    }

    function test_revertWhen_upgradeFromTransition_beforeTheSchedule() public {
        uint256 scheduled = block.timestamp + 1 days;
        CTMTransition transition = _defaultTransition(scheduled);

        vm.expectRevert(abi.encodeWithSelector(TimeNotReached.selector, scheduled, block.timestamp));
        engine.upgradeFromTransition(address(transition));

        // Exactly at the schedule the edge is executable.
        vm.warp(scheduled);
        engine.upgradeFromTransition(address(transition));
        assertEq(engine.getProtocolVersion(), protocolVersion);
    }

    /// @dev A minor hop requires the previous L2 upgrade to have been finalized.
    function test_revertWhen_upgradeFromTransition_previousUpgradeNotFinalized() public {
        bytes32 pending = keccak256("pending");
        engine.setL2SystemContractsUpgradeTxHash(pending);
        CTMTransition transition = _defaultTransition(0);

        vm.expectRevert(abi.encodeWithSelector(PreviousUpgradeNotFinalized.selector, pending));
        engine.upgradeFromTransition(address(transition));
    }

    /// @dev A patch edge (0.1.0 -> 0.1.1) may swap the verifier while the previous minor's L2
    ///      upgrade is still pending; it carries no L2 transaction (the transition refuses one),
    ///      so the pending hash survives it — see `PatchCantSetUpgradeTxn` in BaseZkSyncUpgrade.t.sol
    ///      for the engine-side refusal and StorageRegistries.t.sol for the object-side one.
    function test_upgradeFromTransition_patchKeepsThePendingL2Upgrade() public {
        engine.setProtocolVersion(protocolVersion);
        bytes32 pending = keccak256("pending");
        engine.setL2SystemContractsUpgradeTxHash(pending);
        uint256 patchVersion = SemVer.packSemVer(0, 1, 1);
        CTMRelease patched = _release(_departingFacets(), newVerifier);
        CTMTransition patch = _transition(
            fromRelease,
            patched,
            protocolVersion,
            patchVersion,
            0,
            address(engine),
            _emptyPlan()
        );

        engine.upgradeFromTransition(address(patch));

        assertEq(engine.getProtocolVersion(), patchVersion);
        assertEq(engine.getVerifier(), newVerifier, "a patch may swap the verifier");
        assertEq(
            engine.getL2SystemContractsUpgradeTxHash(),
            pending,
            "a patch leaves the pending L2 upgrade untouched"
        );
    }

    /// @dev The off-chain read: the transaction `upgradeFromTransition` commits, composed for the
    ///      given Bridgehub and chain.
    function test_l2UpgradeTx_isTheComposedTransaction() public {
        CTMTransition transition = _defaultTransition(0);

        L2CanonicalTransaction memory served = engine.l2UpgradeTx(address(transition), mockBridgehub, ETH_CHAIN_ID);

        assertEq(
            keccak256(abi.encode(served)),
            keccak256(abi.encode(_expectedL2Tx(transition.l2Plan(), protocolVersion))),
            "the served transaction is the composed one"
        );
        engine.upgradeFromTransition(address(transition));
        assertEq(engine.getL2SystemContractsUpgradeTxHash(), keccak256(abi.encode(served)), "and the committed one");
    }

    // ─────────────────────────── outstanding batches ───────────────────────────

    /// @dev The engine installs the target release's verifier, so it refuses to run while a
    ///      committed batch still awaits execution (see `BaseZkSyncUpgrade._requireAllBatchesExecuted`).
    function test_revertWhen_upgradeFromTransition_aCommittedBatchIsNotExecuted() public {
        CTMTransition transition = _defaultTransition(0);
        engine.setBatchCounters(8, 7);

        vm.expectRevert(NotAllBatchesExecuted.selector);
        engine.upgradeFromTransition(address(transition));

        engine.setBatchCounters(8, 8);
        engine.upgradeFromTransition(address(transition));
        assertEq(engine.getProtocolVersion(), protocolVersion);
    }

    /// @dev Includes the fresh-chain boundary (0/0), where a chain has committed nothing yet.
    function testFuzz_upgradeFromTransition_outstandingBatchesGuard(uint256 _committed, uint256 _executed) public {
        _committed = bound(_committed, 0, type(uint128).max);
        _executed = bound(_executed, 0, _committed);
        engine.setBatchCounters(_committed, _executed);
        CTMTransition transition = _defaultTransition(0);

        if (_committed != _executed) {
            vm.expectRevert(NotAllBatchesExecuted.selector);
            engine.upgradeFromTransition(address(transition));
        } else {
            engine.upgradeFromTransition(address(transition));
            assertEq(engine.getProtocolVersion(), protocolVersion);
        }
    }

    // ─────────────────────────── one-pass per-chain composition ───────────────────────────

    /// @dev The REAL v34 composer through the engine: the transaction the chain commits carries
    ///      THIS chain's `ZKChainSpecificForceDeploymentsData`, composed in the same pass as the
    ///      rest of the transaction — there is no later rewrite, and the served view IS the
    ///      committed transaction. The ecosystem the composer reads is mocked (see the shared
    ///      fixture); the values that land in the transaction are what is under test.
    function test_upgradeFromTransition_commitsTheTransactionComposedForThisChain() public {
        CTMTransition transition = _v34Transition();
        L2CanonicalTransaction memory expectedTx = _expectedV34L2Tx(transition.l2Plan(), protocolVersion, ETH_CHAIN_ID);
        bytes32 expectedHash = keccak256(abi.encode(expectedTx));

        vm.expectEmit(address(engine));
        emit BaseZkSyncUpgrade.UpgradeComplete(protocolVersion, expectedHash, expectedTx);
        engine.upgradeFromTransition(address(transition));

        assertEq(engine.getL2SystemContractsUpgradeTxHash(), expectedHash, "the chain commits its own composition");
        L2CanonicalTransaction memory served = engine.l2UpgradeTx(address(transition), mockBridgehub, ETH_CHAIN_ID);
        assertEq(keccak256(abi.encode(served)), expectedHash, "the served view is the committed transaction");
        ZKChainSpecificForceDeploymentsData memory data = _perChainData(served.data);
        assertEq(data.baseTokenBridgingData.assetId, ETH_BASE_TOKEN_ASSET_ID, "wrong base token asset id");
        assertEq(data.baseTokenBridgingData.originChainId, ETH_ORIGIN_CHAIN_ID, "wrong origin chain");
        assertEq(data.baseTokenBridgingData.originToken, ETH_TOKEN_ADDRESS, "wrong origin token");
        assertEq(data.baseTokenL1Address, ETH_TOKEN_ADDRESS, "wrong L1 base token address");
        assertEq(data.baseTokenMetadata.name, "Ether", "wrong base token name");
        assertEq(data.baseTokenMetadata.symbol, "ETH", "wrong base token symbol");
        assertEq(data.baseTokenMetadata.decimals, 18, "wrong base token decimals");
    }

    /// @dev An ERC20-based chain: the metadata comes from the token's bridged representation on
    ///      this layer (a REAL token here), not from its origin-chain address, which has no code.
    function test_upgradeFromTransition_readsAnERC20BaseTokenFromItsLocalRepresentation() public {
        engine.setChainId(ERC20_CHAIN_ID);
        CTMTransition transition = _v34Transition();
        L2CanonicalTransaction memory expectedTx = _expectedV34L2Tx(
            transition.l2Plan(),
            protocolVersion,
            ERC20_CHAIN_ID
        );

        engine.upgradeFromTransition(address(transition));

        assertEq(engine.getL2SystemContractsUpgradeTxHash(), keccak256(abi.encode(expectedTx)));
        ZKChainSpecificForceDeploymentsData memory data = _perChainData(
            engine.l2UpgradeTx(address(transition), mockBridgehub, ERC20_CHAIN_ID).data
        );
        assertEq(data.baseTokenMetadata.name, ERC20_NAME, "metadata not read from the local token");
        assertEq(data.baseTokenMetadata.symbol, ERC20_SYMBOL, "wrong symbol");
        assertEq(data.baseTokenMetadata.decimals, ERC20_DECIMALS, "wrong decimals");
        // The bridging data still describes the token on its origin chain.
        assertEq(data.baseTokenL1Address, erc20OriginToken, "wrong L1 base token address");
        assertEq(data.baseTokenBridgingData.originToken, erc20OriginToken, "wrong origin token");
        assertEq(data.baseTokenBridgingData.originChainId, ERC20_ORIGIN_CHAIN_ID, "wrong origin chain");
        assertEq(data.baseTokenBridgingData.assetId, ERC20_BASE_TOKEN_ASSET_ID, "wrong base token asset id");
    }

    /// @dev Two chains of one ecosystem never receive the same transaction: only the per-chain
    ///      half differs, everything ecosystem-wide is shared.
    function test_l2UpgradeTx_isComposedPerChain() public {
        CTMTransition transition = _v34Transition();

        L2CanonicalTransaction memory forEthChain = engine.l2UpgradeTx(
            address(transition),
            mockBridgehub,
            ETH_CHAIN_ID
        );
        L2CanonicalTransaction memory forErc20Chain = engine.l2UpgradeTx(
            address(transition),
            mockBridgehub,
            ERC20_CHAIN_ID
        );

        assertTrue(
            keccak256(abi.encode(forEthChain)) != keccak256(abi.encode(forErc20Chain)),
            "two chains must not share a transaction"
        );
        assertEq(forEthChain.txType, forErc20Chain.txType);
        assertEq(forEthChain.nonce, forErc20Chain.nonce);
        assertEq(abi.encode(forEthChain.factoryDeps), abi.encode(forErc20Chain.factoryDeps));
        (address ethDeployer, bytes memory ethFixed, ) = this.decodeV34Upgrade(_delegateCalldata(forEthChain.data));
        (address erc20Deployer, bytes memory erc20Fixed, ) = this.decodeV34Upgrade(
            _delegateCalldata(forErc20Chain.data)
        );
        assertEq(ethDeployer, erc20Deployer, "the CTM deployer is ecosystem-wide");
        assertEq(ethFixed, erc20Fixed, "the fixed data is ecosystem-wide");
        assertEq(_perChainData(forEthChain.data).baseTokenBridgingData.assetId, ETH_BASE_TOKEN_ASSET_ID);
        assertEq(_perChainData(forErc20Chain.data).baseTokenBridgingData.assetId, ERC20_BASE_TOKEN_ASSET_ID);
    }

    /// @dev The transition is the read entry point and the engine the composition code: the
    ///      object forwards to the pinned engine and serves exactly what the chain commits.
    function test_l2UpgradeTx_transitionForwardsToThePinnedEngine() public {
        CTMTransition transition = _v34Transition();

        vm.expectCall(
            address(engine),
            abi.encodeCall(IDefaultUpgrade.l2UpgradeTx, (address(transition), mockBridgehub, ETH_CHAIN_ID))
        );
        L2CanonicalTransaction memory served = transition.l2UpgradeTx(mockBridgehub, ETH_CHAIN_ID);

        assertEq(
            keccak256(abi.encode(served)),
            keccak256(abi.encode(engine.l2UpgradeTx(address(transition), mockBridgehub, ETH_CHAIN_ID))),
            "the transition serves the engine's composition"
        );
        engine.upgradeFromTransition(address(transition));
        assertEq(engine.getL2SystemContractsUpgradeTxHash(), keccak256(abi.encode(served)), "and the committed one");
    }
}
