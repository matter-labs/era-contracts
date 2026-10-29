// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {AtomicInteropProofBuilder} from "../../unit/concrete/atomic-interop/AtomicInteropProofBuilder.sol";

import {L1AssetRouter} from "contracts/bridge/asset-router/L1AssetRouter.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {AssetRouterBase} from "contracts/bridge/asset-router/AssetRouterBase.sol";
import {IAssetHandler} from "contracts/bridge/interfaces/IAssetHandler.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {IL2NativeTokenVault} from "contracts/bridge/ntv/IL2NativeTokenVault.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1MessageRoot} from "contracts/core/message-root/IL1MessageRoot.sol";
import {L2InteropHandler} from "contracts/interop/interop-handler/L2InteropHandler.sol";
import {IInteropHandlerBase} from "contracts/interop/interop-handler/IInteropHandlerBase.sol";
import {AtomicFinalityProof, AtomicFlow, AtomicFlowPreimage, ImtProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {BundleStatus, InteropBundle} from "contracts/common/Messaging.sol";
import {ChainBatchRootTree} from "contracts/common/libraries/ChainBatchRootTree.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_INTEROP_HANDLER_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {AssetIdNotSupported, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {InteropDepositChainNotOnL1} from "contracts/bridge/L1BridgeContractErrors.sol";
import {OnlyL1AssetRouter} from "contracts/core/bridgehub/L1BridgehubErrors.sol";
import {BundleAlreadyProcessed} from "contracts/interop/InteropErrors.sol";
import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";
import {IL2Bridgehub} from "contracts/core/bridgehub/IL2Bridgehub.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice L1 -> L2 deposits through interop, end to end: a real `L1AssetRouter.depositViaInterop` commits the
/// deposit as a one-leg atomic flow into L1's commitment tree in a real `L1MessageRoot`; the next interop root
/// is imported on the L2; and the unchanged `L2InteropHandler.executeAtomicBundle` proves the leg against it
/// (real `AtomicInteropProof` + `L2MessageVerification`, no verifier mock) and mints the tokens.
/// The VM switches to `L1_CHAIN_ID` for everything that runs on L1. The only mocks are the L1 Bridgehub's
/// getters and the L1 native token vault's burn, whose code this path does not change.
abstract contract L1InteropDepositTestAbstract is L2InteropTestUtils, AtomicInteropProofBuilder {
    using stdStorage for StdStorage;

    uint256 internal constant DEPOSIT_AMOUNT = 1_000;

    L1AssetRouter internal l1Router;
    address internal l1NativeTokenVault = makeAddr("l1NativeTokenVault");
    uint256 internal l2ChainId;

    /// @dev The real atomic flow manager is deployed by {_setUpL1DepositStack}; drop the shared deployer's mock.
    function _mockAtomicFlowManager() internal virtual override {}

    function _setUpL1DepositStack() internal {
        _deployAtomicPredeploys(L1_CHAIN_ID, true);
        l2ChainId = block.chainid;

        vm.chainId(L1_CHAIN_ID);
        // The settlement-layer MessageRoot runs on L1, so its own slot (shared-tree index 0) is L1's.
        _setUpAtomicFixtures();
        builderSlChainId = L1_CHAIN_ID;
        // The destination is registered in L1's MessageRoot like any chain settling on L1.
        _ensureChainRegistered(l2ChainId);

        // The real L1 asset router, at the address the L2 asset router knows as its L1 counterpart.
        deployCodeTo(
            "L1AssetRouter.sol:L1AssetRouter",
            abi.encode(makeAddr("l1Weth"), msgRootBridgehub, makeAddr("l1Nullifier")),
            l1AssetRouter
        );
        l1Router = L1AssetRouter(l1AssetRouter);
        stdstore.target(l1AssetRouter).sig("owner()").checked_write(address(this));
        vm.etch(l1NativeTokenVault, hex"00");
        l1Router.setNativeTokenVault(INativeTokenVaultBase(l1NativeTokenVault));

        vm.mockCall(
            msgRootBridgehub,
            abi.encodeWithSelector(IBridgehubBase.assetRouter.selector),
            abi.encode(l1AssetRouter)
        );
        vm.mockCall(
            msgRootBridgehub,
            abi.encodeWithSelector(IBridgehubBase.messageRoot.selector),
            abi.encode(address(slMessageRoot))
        );
        vm.mockCall(
            msgRootBridgehub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, l2ChainId),
            abi.encode(L1_CHAIN_ID)
        );
        vm.mockCall(
            msgRootBridgehub,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, l2ChainId),
            abi.encode(baseTokenAssetId)
        );

        vm.chainId(l2ChainId);
    }

    function _l1TokenAssetId() internal view returns (bytes32) {
        return DataEncoding.encodeNTVAssetId(L1_CHAIN_ID, L1_TOKEN_ADDRESS);
    }

    /// @dev Deposits `DEPOSIT_AMOUNT` of the L1 token to `_receiver` through interop, on L1. The vault's burn
    /// returns the bridge-mint data the real L1 vault produces for an L1-native token.
    function _depositViaInterop(
        address _depositor,
        address _receiver
    ) internal returns (bytes32 bundleHash, uint256 l1BatchNumber, AtomicFlowPreimage memory preimage, InteropBundle memory bundle) {
        bytes memory transferData = DataEncoding.encodeBridgeBurnData(DEPOSIT_AMOUNT, _receiver, L1_TOKEN_ADDRESS);
        vm.mockCall(
            l1NativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.tryRegisterTokenFromBurnData.selector),
            ""
        );
        vm.mockCall(
            l1NativeTokenVault,
            abi.encodeWithSelector(IAssetHandler.bridgeBurn.selector),
            abi.encode(
                DataEncoding.encodeBridgeMintData({
                    _originalCaller: _depositor,
                    _remoteReceiver: _receiver,
                    _originToken: L1_TOKEN_ADDRESS,
                    _amount: DEPOSIT_AMOUNT,
                    _erc20Metadata: encodeTokenData(TOKEN_DEFAULT_NAME, TOKEN_DEFAULT_SYMBOL, TOKEN_DEFAULT_DECIMALS)
                })
            )
        );

        uint256 currentChainId = block.chainid;
        vm.chainId(L1_CHAIN_ID);
        vm.recordLogs();
        vm.prank(_depositor);
        bundleHash = l1Router.depositViaInterop(l2ChainId, _l1TokenAssetId(), transferData, 0);
        (l1BatchNumber, preimage, bundle) = _committedDeposit(vm.getRecordedLogs());
        vm.chainId(currentChainId);
    }

    function _committedDeposit(
        Vm.Log[] memory _logs
    ) internal view returns (uint256 l1BatchNumber, AtomicFlowPreimage memory preimage, InteropBundle memory bundle) {
        for (uint256 i = 0; i < _logs.length; ++i) {
            if (_logs[i].emitter == l1AssetRouter && _logs[i].topics[0] == IL1AssetRouter.InteropDepositCommitted.selector) {
                return abi.decode(_logs[i].data, (uint256, AtomicFlowPreimage, InteropBundle));
            }
        }
        revert("no InteropDepositCommitted event");
    }

    /// @dev Imports the current L1 interop root on the L2 and builds the finality proof of the deposit's leg,
    /// committed in L1's first post-genesis batch. Genesis and that batch settle in the same block.
    function _finalityOfFirstDeposit(
        AtomicFlowPreimage memory _preimage
    ) internal returns (AtomicFinalityProof memory finality) {
        uint256 currentChainId = block.chainid;
        vm.chainId(L1_CHAIN_ID);
        IL1MessageRoot l1MessageRoot = IL1MessageRoot(address(slMessageRoot));
        uint256 batchTs = slMessageRoot.chainBatchRootTimestamp(L1_CHAIN_ID, FIRST_POST_GENESIS_BATCH);
        bytes32 genesisLeaf = MessageHashing.batchLeafHash(
            ChainBatchRootTree.genesisChainBatchRoot(),
            0,
            slMessageRoot.chainBatchRootTimestamp(L1_CHAIN_ID, 0)
        );
        bytes32 imtEnd = l1MessageRoot.l1CommitmentTreeRoot();
        (uint256 slBlock, ) = _importCurrentSharedRoot();

        ImtProof memory proof = ImtProof({
            sourceChainId: L1_CHAIN_ID,
            batchNumber: FIRST_POST_GENESIS_BATCH,
            chainImtRoot: imtEnd,
            provesAgainstBeginRoot: false,
            settlementProof: _realFirstPostGenesisBatchSettlementProof(
                L1_CHAIN_ID,
                FIRST_POST_GENESIS_BATCH,
                ChainBatchRootTree.IMT_END_ROOT_LEAF_INDEX,
                ChainBatchRootTree.EMPTY_IMT_ROOT,
                imtEnd,
                batchTs,
                genesisLeaf,
                slBlock
            ),
            leaf: l1MessageRoot.l1CommitmentTreeLeafAt(1),
            imtLeafIndex: 1,
            imtProof: l1MessageRoot.l1CommitmentTreeMerklePath(1)
        });
        vm.chainId(currentChainId);

        finality.flow = AtomicFlow({flowId: keccak256(abi.encode(_preimage)), preimage: _preimage});
        finality.proofs = new ImtProof[](1);
        finality.proofs[0] = proof;
    }

    /// @notice The happy path: the deposit settles as L1's first batch, reaches the L2 in the imported interop
    /// root, and executes there through `executeAtomicBundle`, deploying the bridged token and minting to the
    /// receiver — no priority transaction involved.
    function test_depositViaInterop_ExecutesOnL2ThroughInteropRoot() public {
        _setUpL1DepositStack();
        address receiver = makeAddr("interop deposit receiver");
        (bytes32 bundleHash, uint256 l1BatchNumber, AtomicFlowPreimage memory preimage, InteropBundle memory bundle) = _depositViaInterop(
            makeAddr("depositor"),
            receiver
        );

        assertEq(l1BatchNumber, FIRST_POST_GENESIS_BATCH, "the first L1 leg settles in L1's first post-genesis batch");
        assertEq(bundle.sourceChainId, L1_CHAIN_ID, "sourced on L1");
        assertEq(bundle.destinationChainId, l2ChainId, "destined for the L2");
        assertEq(bundle.calls[0].from, l1AssetRouter, "sent by the L1 asset router");
        assertEq(bundle.calls[0].to, L2_ASSET_ROUTER_ADDR, "to the L2 asset router");
        assertEq(preimage.legBundleHashes[0], bundleHash, "a one-leg flow");
        assertEq(preimage.legSourceChainIds[0], L1_CHAIN_ID, "whose leg is sourced on L1");

        AtomicFinalityProof memory finality = _finalityOfFirstDeposit(preimage);

        vm.chainId(l2ChainId);
        // L1 is never a whitelisted peer; the receive filter accepts its legs anyway.
        assertFalse(IL2Bridgehub(L2_BRIDGEHUB_ADDR).isPeerAllowed(L1_CHAIN_ID), "L1 is not a whitelisted peer");
        vm.expectEmit(true, true, true, true, L2_INTEROP_HANDLER_ADDR);
        emit IInteropHandlerBase.BundleExecuted(bundleHash);
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).executeAtomicBundle(abi.encode(bundle), finality);

        address l2Token = IL2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).l2TokenAddress(L1_TOKEN_ADDRESS);
        assertTrue(l2Token != address(0), "the first deposit deploys the bridged token");
        assertEq(IERC20(l2Token).balanceOf(receiver), DEPOSIT_AMOUNT, "the receiver is credited");
        assertEq(
            uint256(L2InteropHandler(L2_INTEROP_HANDLER_ADDR).bundleStatus(bundleHash)),
            uint256(BundleStatus.FullyExecuted),
            "bundle FullyExecuted"
        );

        vm.expectRevert(abi.encodeWithSelector(BundleAlreadyProcessed.selector, bundleHash));
        L2InteropHandler(L2_INTEROP_HANDLER_ADDR).executeAtomicBundle(abi.encode(bundle), finality);
    }

    /// @notice Each L1 leg is its own batch of L1, and its chain batch root carries L1's commitment tree before
    /// and after the insert, so `begin(N) == end(N-1)` holds for L1 as for any ZKsync OS chain. Two identical
    /// deposits get different bundles (the router's nonce is the salt).
    function test_depositViaInterop_ConsecutiveDepositsSettleAsConsecutiveL1Batches() public {
        _setUpL1DepositStack();
        address depositor = makeAddr("depositor");
        address receiver = makeAddr("interop deposit receiver");
        IL1MessageRoot l1MessageRoot = IL1MessageRoot(address(slMessageRoot));

        (bytes32 firstHash, uint256 firstBatch, , ) = _depositViaInterop(depositor, receiver);
        bytes32 rootAfterFirst = l1MessageRoot.l1CommitmentTreeRoot();
        (bytes32 secondHash, uint256 secondBatch, , ) = _depositViaInterop(depositor, receiver);
        bytes32 rootAfterSecond = l1MessageRoot.l1CommitmentTreeRoot();

        assertTrue(firstHash != secondHash, "identical deposits get distinct bundles");
        assertEq(firstBatch, 1, "first batch");
        assertEq(secondBatch, 2, "second batch");
        assertEq(l1MessageRoot.l1CommitmentTreeLeafCount(), 3, "sentinel + two legs");
        assertEq(slMessageRoot.currentChainBatchNumber(L1_CHAIN_ID), 2, "L1's batch counter");
        assertEq(slMessageRoot.chainTreeLeafCount(L1_CHAIN_ID), 3, "genesis + two batches in L1's chain tree");
        assertEq(
            slMessageRoot.chainBatchRoots(L1_CHAIN_ID, 1),
            ChainBatchRootTree.compute(bytes32(0), bytes32(0), ChainBatchRootTree.EMPTY_IMT_ROOT, rootAfterFirst),
            "batch 1 spans the empty tree to the first leg"
        );
        assertEq(
            slMessageRoot.chainBatchRoots(L1_CHAIN_ID, 2),
            ChainBatchRootTree.compute(bytes32(0), bytes32(0), rootAfterFirst, rootAfterSecond),
            "batch 2 begins where batch 1 ended"
        );
    }

    /// @notice Only the L1 asset router may commit L1 legs.
    function test_commitL1Leg_RevertWhen_NotL1AssetRouter() public {
        _setUpL1DepositStack();
        address stranger = makeAddr("stranger");
        vm.chainId(L1_CHAIN_ID);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(OnlyL1AssetRouter.selector, stranger, l1AssetRouter));
        IL1MessageRoot(address(slMessageRoot)).commitL1Leg(1, 0);
    }

    /// @notice The destination proves the leg against an imported L1 root, so it must settle on L1.
    function test_depositViaInterop_RevertWhen_DestinationNotOnL1() public {
        _setUpL1DepositStack();
        vm.mockCall(
            msgRootBridgehub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, l2ChainId),
            abi.encode(uint256(506))
        );
        vm.chainId(L1_CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(InteropDepositChainNotOnL1.selector, l2ChainId));
        l1Router.depositViaInterop(l2ChainId, _l1TokenAssetId(), hex"", 0);
    }

    /// @notice The destination's base token is not an asset-router deposit, as on the two-bridges path.
    function test_depositViaInterop_RevertWhen_BaseTokenAsset() public {
        _setUpL1DepositStack();
        vm.chainId(L1_CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(AssetIdNotSupported.selector, baseTokenAssetId));
        l1Router.depositViaInterop(l2ChainId, baseTokenAssetId, hex"", 0);
    }

    /// @notice On the L2, an L1-sourced interop message is accepted from the L1 asset router only.
    function test_l2AssetRouterReceiveMessage_RevertWhen_L1SenderNotL1AssetRouter() public {
        address impostor = makeAddr("impostor");
        bytes memory payload = abi.encodeCall(AssetRouterBase.finalizeDeposit, (L1_CHAIN_ID, _l1TokenAssetId(), hex""));
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, impostor));
        AssetRouterBase(L2_ASSET_ROUTER_ADDR).receiveMessage(
            bytes32(0),
            InteroperableAddress.formatEvmV1(L1_CHAIN_ID, impostor),
            payload
        );
    }
}
