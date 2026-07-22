// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
// solhint-disable gas-custom-errors

import {L2InteropTestUtils} from "./L2InteropTestUtils.sol";
import {AtomicInteropProofBuilder} from "../../unit/concrete/atomic-interop/AtomicInteropProofBuilder.sol";
import {InteropLibrary} from "deploy-scripts/InteropLibrary.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {AtomicFlowPreimage, ImtProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IERC7786Attributes} from "contracts/interop/IERC7786Attributes.sol";
import {InteropCallStarter} from "contracts/common/Messaging.sol";
import {InteroperableAddress} from "contracts/vendor/draft-InteroperableAddress.sol";
import {
    L2_ASSET_ROUTER_ADDR,
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {L2_NATIVE_TOKEN_VAULT} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

/// @notice Shared fixtures for the atomic-interop integration suites (send/refund and
/// execute/finalize): deploys the atomic predeploys at their canonical addresses on top of the
/// shared L2-in-L1-context deployment and provides the send-side helpers every atomic flow needs.
/// Everything runs through the REAL entry points (InteropCenter send, AssetRouter burn,
/// AtomicFlowManager append, L2InteropCommitmentTree insert); the only logic mock is the
/// separately-tested cross-chain leaf verifier inherited from {AtomicInteropProofBuilder}.
abstract contract L2AtomicInteropTestBase is L2InteropTestUtils, AtomicInteropProofBuilder {
    /// @dev Deploys the atomic predeploys at their canonical addresses (the shared L2-in-L1 deployer
    /// does not include them) and the proof fixtures. Called at the start of each test rather than in
    /// `setUp` to stay independent of the deployer's own setUp chain.
    function _setUpAtomicStack() internal {
        deployCodeTo("AtomicFlowManager.sol:AtomicFlowManager", L2_ATOMIC_FLOW_MANAGER_ADDR);
        deployCodeTo("L2InteropCommitmentTree.sol:L2InteropCommitmentTree", L2_INTEROP_COMMITMENT_TREE_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR).initL2(L1_CHAIN_ID);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR).initL2();
        // Proof fixtures from the builder: `tree` acts as the REMOTE chain's IMT oracle, plus the
        // real L2InteropRootStorage etched at its canonical address for the timeout clock.
        _setUpAtomicFixtures();
    }

    /// @dev The exact single-call token-transfer starter `InteropLibrary.sendToken` sends: an indirect
    /// call through the L2 AssetRouter, which burns `_amount` of `_l2Token` from the sender and mints
    /// to `_receiver` on the destination.
    function _tokenCallStarter(
        address _l2Token,
        uint256 _amount,
        address _receiver
    ) internal view returns (InteropCallStarter[] memory calls) {
        bytes memory secondBridgeCalldata = InteropLibrary.buildSecondBridgeCalldata(
            L2_NATIVE_TOKEN_VAULT.assetId(_l2Token),
            _amount,
            _receiver,
            address(0)
        );
        calls = new InteropCallStarter[](1);
        calls[0] = InteropLibrary.buildSecondBridgeCall(secondBridgeCalldata, L2_ASSET_ROUTER_ADDR);
    }

    /// @dev Predicts the bundle hash the atomic send will produce: a non-atomic dry run with the same
    /// calls and salt on a state snapshot (the atomic metadata is not part of the bundle, so the hash
    /// is identical). This is the foundry equivalent of the off-chain `callStatic` preview users do.
    function _predictBundleHash(
        InteropCallStarter[] memory _calls,
        bytes32 _salt
    ) internal returns (bytes32 predicted) {
        bytes[] memory attrs = new bytes[](1);
        attrs[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (_salt));
        uint256 snapshotId = vm.snapshotState();
        predicted = l2InteropCenter.sendBundle(InteroperableAddress.formatEvmV1(destinationChainId), _calls, attrs);
        vm.revertToState(snapshotId);
    }

    function _flowIdOf(AtomicFlowPreimage memory _preimage) internal pure returns (bytes32) {
        return keccak256(abi.encode(_preimage));
    }

    function _atomicAttributes(
        AtomicFlowPreimage memory _preimage,
        bytes32 _salt
    ) internal pure returns (bytes[] memory attrs) {
        attrs = new bytes[](2);
        attrs[0] = abi.encodeCall(IERC7786Attributes.interopBundleSalt, (_salt));
        // Low-nullifier index 0: the canonical commitment tree is fresh (genesis head leaf only).
        attrs[1] = abi.encodeCall(IERC7786Attributes.atomicBundle, (_preimage, 0));
    }

    /// @dev Inclusion proof for a commit value inserted into the CANONICAL commitment tree (the one
    /// the real atomic send populated) — the mirror of the builder's oracle-tree `_inclusionProof`,
    /// used for the local leg whose commitment went through the production path.
    function _canonicalTreeInclusionProof(
        uint256 _sourceChainId,
        uint256 _batchNumber,
        uint256 _leafIndex,
        uint256 _slBlock,
        uint256 _l1Timestamp
    ) internal view returns (ImtProof memory) {
        L2InteropCommitmentTree canonicalTree = L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR);
        return
            ImtProof({
                sourceChainId: _sourceChainId,
                batchNumber: _batchNumber,
                chainImtRoot: canonicalTree.root(),
                // The finality path always authenticates the end root; the branch bool is ignored.
                provesAgainstBeginRoot: false,
                settlementProof: _settlementProof(L1_CHAIN_ID, _slBlock, _l1Timestamp, new bytes32[](0)),
                leaf: canonicalTree.leafAt(_leafIndex),
                imtLeafIndex: _leafIndex,
                imtProof: canonicalTree.merklePath(_leafIndex)
            });
    }
}
