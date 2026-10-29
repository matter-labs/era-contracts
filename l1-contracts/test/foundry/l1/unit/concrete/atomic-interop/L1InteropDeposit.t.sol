// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {L2AssetRouter} from "contracts/bridge/asset-router/L2AssetRouter.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IAssetHandler} from "contracts/bridge/interfaces/IAssetHandler.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {AtomicFinalityProof, AtomicFlow, AtomicFlowPreimage, ImtProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {BundleAttributes, InteropBundle} from "contracts/common/Messaging.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {L2_ASSET_ROUTER_ADDR, L2_INTEROP_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {AssetIdNotSupported} from "contracts/common/L1ContractErrors.sol";
import {InteropDepositChainNotOnL1} from "contracts/bridge/L1BridgeContractErrors.sol";
import {OnlyL1AssetRouter} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {ManagerExecutingBundleNotInFlow, ProofDeadlineExceeded} from "contracts/atomic-interop/AtomicInteropErrors.sol";

/// @dev Exposes the L2 asset router's interop-sender rule.
contract L2AssetRouterSenderHarness is L2AssetRouter {
    function isValidInteropSender(uint256 _senderChainId, address _senderAddress) external view returns (bool) {
        return _isValidInteropSender(_senderChainId, _senderAddress);
    }
}

/// @notice L1 -> L2 deposits through interop. A real `L1AssetRouter.depositViaInterop` commits the deposit as a
/// one-leg atomic flow into L1's commitment tree in a real `L1MessageRoot`; the shared root is imported on the
/// L2; and the unchanged L2 atomicity gate, `AtomicFlowManager.requireFlowFinalized` (the check
/// `executeAtomicBundle` runs), accepts the leg through the real `AtomicInteropProof`, `L2MessageVerification`
/// and `L2InteropRootStorage`. Mocked: the L1 Bridgehub's getters and the L1 vault's burn, which this path does
/// not change. `block.chainid` is L1 except where a test switches to the L2.
contract L1InteropDepositTest is AtomicInteropProofBuilder {
    using stdStorage for StdStorage;

    uint256 internal constant L2_CHAIN_ID = 271;
    uint256 internal constant DEPOSIT_AMOUNT = 1_000;

    uint256 internal l1ChainId;
    L1AssetRouter internal router;
    AtomicFlowManager internal manager;
    address internal l1NativeTokenVault = makeAddr("l1NativeTokenVault");
    address internal l1Token = makeAddr("l1Token");
    bytes32 internal l2BaseTokenAssetId = keccak256("l2 base token asset id");

    function setUp() public {
        l1ChainId = block.chainid;
        _setUpAtomicFixtures();
        builderSlChainId = l1ChainId;
        (manager, ) = _deployAtomicPredeploys(l1ChainId, false);
        // The destination is registered in L1's MessageRoot like any chain settling on L1.
        _ensureChainRegistered(L2_CHAIN_ID);

        router = L1AssetRouter(
            address(
                new TransparentUpgradeableProxy(
                    address(
                        new L1AssetRouter(makeAddr("l1Weth"), msgRootBridgehub, makeAddr("l1Nullifier"))
                    ),
                    makeAddr("proxyAdmin"),
                    abi.encodeCall(L1AssetRouter.initialize, (address(this)))
                )
            )
        );
        vm.etch(l1NativeTokenVault, hex"00");
        router.setNativeTokenVault(INativeTokenVaultBase(l1NativeTokenVault));

        vm.mockCall(msgRootBridgehub, abi.encodeWithSelector(IBridgehubBase.assetRouter.selector), abi.encode(router));
        vm.mockCall(
            msgRootBridgehub,
            abi.encodeWithSelector(IBridgehubBase.messageRoot.selector),
            abi.encode(address(slMessageRoot))
        );
        vm.mockCall(
            msgRootBridgehub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, L2_CHAIN_ID),
            abi.encode(l1ChainId)
        );
        vm.mockCall(
            msgRootBridgehub,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, L2_CHAIN_ID),
            abi.encode(l2BaseTokenAssetId)
        );
    }

    function _assetId() internal view returns (bytes32) {
        return DataEncoding.encodeNTVAssetId(l1ChainId, l1Token);
    }

    function _bridgeMintData(address _depositor, address _receiver) internal view returns (bytes memory) {
        return
            DataEncoding.encodeBridgeMintData({
                _originalCaller: _depositor,
                _remoteReceiver: _receiver,
                _originToken: l1Token,
                _amount: DEPOSIT_AMOUNT,
                _erc20Metadata: hex""
            });
    }

    /// @dev Deposits through interop. The vault's burn returns the bridge-mint data the real vault produces.
    function _deposit(
        address _depositor,
        address _receiver
    )
        internal
        returns (bytes32 bundleHash, uint256 l1BatchNumber, AtomicFlowPreimage memory preimage, InteropBundle memory bundle)
    {
        vm.mockCall(
            l1NativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.tryRegisterTokenFromBurnData.selector),
            ""
        );
        vm.mockCall(
            l1NativeTokenVault,
            abi.encodeWithSelector(IAssetHandler.bridgeBurn.selector),
            abi.encode(_bridgeMintData(_depositor, _receiver))
        );
        vm.recordLogs();
        vm.prank(_depositor);
        bundleHash = router.depositViaInterop(
            L2_CHAIN_ID,
            _assetId(),
            DataEncoding.encodeBridgeBurnData(DEPOSIT_AMOUNT, _receiver, l1Token),
            0
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(router) && logs[i].topics[0] == IL1AssetRouter.InteropDepositCommitted.selector) {
                (l1BatchNumber, preimage, bundle) = abi.decode(logs[i].data, (uint256, AtomicFlowPreimage, InteropBundle));
                return (bundleHash, l1BatchNumber, preimage, bundle);
            }
        }
        revert("no InteropDepositCommitted event");
    }

    /// @dev Imports the current L1 interop root on the L2 and builds the finality proof of the leg committed in
    /// L1's first post-genesis batch (genesis and that batch settle in the same block).
    function _finalityOfFirstDeposit(
        AtomicFlowPreimage memory _preimage
    ) internal returns (AtomicFinalityProof memory finality) {
        IL1MessageRoot l1MessageRoot = IL1MessageRoot(address(slMessageRoot));
        bytes32 genesisLeaf = MessageHashing.batchLeafHash(
            ChainBatchRootTree.genesisChainBatchRoot(),
            0,
            slMessageRoot.chainBatchRootTimestamp(l1ChainId, 0)
        );
        bytes32 imtEnd = l1MessageRoot.l1CommitmentTreeRoot();
        (uint256 slBlock, ) = _importCurrentSharedRoot();

        finality.flow = AtomicFlow({flowId: keccak256(abi.encode(_preimage)), preimage: _preimage});
        finality.proofs = new ImtProof[](1);
        finality.proofs[0] = ImtProof({
            sourceChainId: l1ChainId,
            batchNumber: FIRST_POST_GENESIS_BATCH,
            chainImtRoot: imtEnd,
            provesAgainstBeginRoot: false,
            settlementProof: _realFirstPostGenesisBatchSettlementProof(
                l1ChainId,
                FIRST_POST_GENESIS_BATCH,
                ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
                ChainBatchRootTree.EMPTY_IMT_ROOT,
                imtEnd,
                slMessageRoot.chainBatchRootTimestamp(l1ChainId, FIRST_POST_GENESIS_BATCH),
                genesisLeaf,
                slBlock
            ),
            leaf: l1MessageRoot.l1CommitmentTreeLeafAt(1),
            imtLeafIndex: 1,
            imtProof: l1MessageRoot.l1CommitmentTreeMerklePath(1)
        });
    }

    /// @notice A deposit settles as L1's first batch, reaches the L2 in the imported interop root, and passes the
    /// L2's atomicity gate exactly like an L2 -> L2 leg. No priority transaction is involved.
    function test_depositViaInterop_PassesL2AtomicityGateThroughInteropRoot() public {
        address depositor = makeAddr("depositor");
        address receiver = makeAddr("receiver");
        (bytes32 bundleHash, uint256 l1BatchNumber, AtomicFlowPreimage memory preimage, InteropBundle memory bundle) = _deposit(
            depositor,
            receiver
        );

        assertEq(l1BatchNumber, FIRST_POST_GENESIS_BATCH, "the first L1 leg settles in L1's first post-genesis batch");
        assertEq(bundleHash, InteropDataEncoding.encodeInteropBundleHash(abi.encode(bundle)), "bundle hash");
        assertEq(preimage.legBundleHashes.length, 1, "a one-leg flow");
        assertEq(preimage.legBundleHashes[0], bundleHash, "whose leg is the deposit");
        assertEq(preimage.legSourceChainIds[0], l1ChainId, "sourced on L1");
        assertEq(preimage.settlementLayerChainId, l1ChainId, "settling on L1");
        assertEq(uint256(preimage.deadline), block.timestamp, "final in the block that commits it");

        _requireFinalOnL2(preimage, bundleHash);
    }

    /// @dev Runs the L2 atomicity gate, as `executeAtomicBundle` does, against the imported L1 root.
    function _requireFinalOnL2(AtomicFlowPreimage memory _preimage, bytes32 _bundleHash) internal {
        AtomicFinalityProof memory finality = _finalityOfFirstDeposit(_preimage);
        vm.chainId(L2_CHAIN_ID);
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        manager.requireFlowFinalized(_bundleHash, finality);
    }

    /// @notice The bundle is the one the L2 executes: one zero-value call from the L1 asset router to the L2 asset
    /// router's `finalizeDeposit`, sourced on L1, with the destination's base token, permissionless execution and
    /// the depositor (pinned to L1) as unbundler.
    function test_depositViaInterop_BundleIsAFinalizeDepositFromTheL1AssetRouter() public {
        address depositor = makeAddr("depositor");
        address receiver = makeAddr("receiver");
        (, , , InteropBundle memory bundle) = _deposit(depositor, receiver);

        assertEq(bundle.sourceChainId, l1ChainId, "source");
        assertEq(bundle.destinationChainId, L2_CHAIN_ID, "destination");
        assertEq(bundle.destinationBaseTokenAssetId, l2BaseTokenAssetId, "destination base token");
        assertEq(bundle.calls.length, 1, "one call");
        assertEq(bundle.calls[0].from, address(router), "from the L1 asset router");
        assertEq(bundle.calls[0].to, L2_ASSET_ROUTER_ADDR, "to the L2 asset router");
        assertEq(bundle.calls[0].value, 0, "zero value");
        assertEq(
            bundle.calls[0].data,
            abi.encodeCall(AssetRouterBase.finalizeDeposit, (l1ChainId, _assetId(), _bridgeMintData(depositor, receiver))),
            "finalizeDeposit from L1"
        );
        BundleAttributes memory attributes = bundle.bundleAttributes;
        assertEq(attributes.executionAddress.length, 0, "permissionless execution");
        assertEq(attributes.unbundlerAddress, InteroperableAddress.formatEvmV1(l1ChainId, depositor), "unbundler");
        assertEq(attributes.salt, bytes32(0), "first nonce");
        assertEq(bundle.interopBundleSalt, keccak256(abi.encodePacked(depositor, bytes32(0))), "salt scheme");
        assertEq(router.interopDepositNonce(), 1, "nonce advanced");
    }

    /// @notice The gate rejects a bundle that is not the committed leg (here: the receiver swapped).
    function test_depositViaInterop_RevertWhen_ExecutingBundleNotTheCommittedLeg() public {
        (bytes32 bundleHash, , AtomicFlowPreimage memory preimage, InteropBundle memory bundle) = _deposit(
            makeAddr("depositor"),
            makeAddr("receiver")
        );
        AtomicFinalityProof memory finality = _finalityOfFirstDeposit(preimage);

        bundle.calls[0].data = abi.encodeCall(
            AssetRouterBase.finalizeDeposit,
            (l1ChainId, _assetId(), _bridgeMintData(makeAddr("depositor"), makeAddr("thief")))
        );
        bytes32 forgedHash = InteropDataEncoding.encodeInteropBundleHash(abi.encode(bundle));
        assertTrue(forgedHash != bundleHash, "forged bundle differs");

        vm.chainId(L2_CHAIN_ID);
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(ManagerExecutingBundleNotInFlow.selector, finality.flow.flowId, forgedHash));
        manager.requireFlowFinalized(forgedHash, finality);
    }

    /// @notice A leg is final only in the batch of L1 that commits it: a flow claiming an earlier deadline fails.
    function test_depositViaInterop_RevertWhen_DeadlineBeforeTheCommittingBatch() public {
        (, , AtomicFlowPreimage memory preimage, ) = _deposit(makeAddr("depositor"), makeAddr("receiver"));
        uint256 committedAt = block.timestamp;
        AtomicFinalityProof memory finality = _finalityOfFirstDeposit(preimage);
        finality.flow.preimage.deadline = uint64(committedAt - 1);
        finality.flow.flowId = keccak256(abi.encode(finality.flow.preimage));

        vm.chainId(L2_CHAIN_ID);
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(ProofDeadlineExceeded.selector, committedAt, committedAt - 1));
        manager.requireFlowFinalized(preimage.legBundleHashes[0], finality);
    }

    /// @notice Each L1 leg is its own batch of L1, whose chain batch root carries L1's commitment tree before and
    /// after the insert, so `begin(N) == end(N-1)` holds for L1. Identical deposits get distinct bundles.
    function test_depositViaInterop_ConsecutiveDepositsSettleAsConsecutiveL1Batches() public {
        IL1MessageRoot l1MessageRoot = IL1MessageRoot(address(slMessageRoot));
        address depositor = makeAddr("depositor");
        address receiver = makeAddr("receiver");

        (bytes32 firstHash, uint256 firstBatch, , ) = _deposit(depositor, receiver);
        bytes32 rootAfterFirst = l1MessageRoot.l1CommitmentTreeRoot();
        vm.roll(block.number + 1);
        (bytes32 secondHash, uint256 secondBatch, , ) = _deposit(depositor, receiver);
        bytes32 rootAfterSecond = l1MessageRoot.l1CommitmentTreeRoot();

        assertTrue(firstHash != secondHash, "identical deposits get distinct bundles");
        assertEq(firstBatch, 1, "first batch");
        assertEq(secondBatch, 2, "second batch");
        assertEq(l1MessageRoot.l1CommitmentTreeLeafCount(), 3, "sentinel + two legs");
        assertEq(slMessageRoot.currentChainBatchNumber(l1ChainId), 2, "L1's batch counter");
        assertEq(slMessageRoot.chainTreeLeafCount(l1ChainId), 3, "genesis + two batches in L1's chain tree");
        assertEq(
            slMessageRoot.chainBatchRoots(l1ChainId, 1),
            ChainBatchRootTree.compute(bytes32(0), bytes32(0), ChainBatchRootTree.EMPTY_IMT_ROOT, rootAfterFirst),
            "batch 1 spans the empty tree to the first leg"
        );
        assertEq(
            slMessageRoot.chainBatchRoots(l1ChainId, 2),
            ChainBatchRootTree.compute(bytes32(0), bytes32(0), rootAfterFirst, rootAfterSecond),
            "batch 2 begins where batch 1 ended"
        );
        assertEq(
            slMessageRoot.historicalRoot(block.number).root,
            slMessageRoot.getAggregatedRoot(),
            "the block's interop root carries the latest leg"
        );
    }

    /// @notice Only the L1 asset router may commit L1 legs.
    function test_commitL1Leg_RevertWhen_NotL1AssetRouter() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OnlyL1AssetRouter.selector, stranger, address(router)));
        IL1MessageRoot(address(slMessageRoot)).commitL1Leg(1, 0);
    }

    /// @notice The destination proves the leg against an imported L1 root, so it must settle on L1.
    function test_depositViaInterop_RevertWhen_DestinationNotOnL1() public {
        vm.mockCall(
            msgRootBridgehub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, L2_CHAIN_ID),
            abi.encode(uint256(506))
        );
        vm.expectRevert(abi.encodeWithSelector(InteropDepositChainNotOnL1.selector, L2_CHAIN_ID));
        router.depositViaInterop(L2_CHAIN_ID, _assetId(), hex"", 0);
    }

    /// @notice The destination's base token is not an asset-router deposit, as on the two-bridges path.
    function test_depositViaInterop_RevertWhen_BaseTokenAsset() public {
        vm.expectRevert(abi.encodeWithSelector(AssetIdNotSupported.selector, l2BaseTokenAssetId));
        router.depositViaInterop(L2_CHAIN_ID, l2BaseTokenAssetId, hex"", 0);
    }

    /// @notice On the L2, an interop message from L1 is accepted from the L1 asset router only; from other chains,
    /// from the L2 asset router as before.
    function test_l2AssetRouter_AcceptsL1SenderOnlyIfL1AssetRouter() public {
        L2AssetRouterSenderHarness l2Router = new L2AssetRouterSenderHarness();
        stdstore.target(address(l2Router)).sig("L1_CHAIN_ID()").checked_write(l1ChainId);
        stdstore.target(address(l2Router)).sig("L1_ASSET_ROUTER()").checked_write(address(router));

        assertTrue(l2Router.isValidInteropSender(l1ChainId, address(router)), "L1 asset router from L1");
        assertFalse(l2Router.isValidInteropSender(l1ChainId, makeAddr("impostor")), "anyone else from L1");
        assertFalse(l2Router.isValidInteropSender(l1ChainId, address(l2Router)), "the L2 router address from L1");
        assertTrue(l2Router.isValidInteropSender(L2_CHAIN_ID, address(l2Router)), "the L2 router from an L2");
        assertFalse(l2Router.isValidInteropSender(L2_CHAIN_ID, address(router)), "the L1 router address from an L2");
    }
}
