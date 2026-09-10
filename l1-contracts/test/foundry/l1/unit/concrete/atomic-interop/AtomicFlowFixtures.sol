// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {
    AtomicFlowPreimage,
    ATOMIC_COMMIT_LEAF_TAG,
    ATOMIC_FLOW_PREIMAGE_VERSION
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {BundleAttributes} from "contracts/common/Messaging.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Shared fixtures for the atomic-interop suites.
/// @dev `commitValue` and `flowId` restate on-chain formulas, so they live here once: an extra copy is
/// a chance for a test to verify against a value production never produces. `AtomicInteropProof`'s
/// `testFuzz_commitValue_matchesSpec` deliberately keeps its own restatement — it is the spec
/// assertion, and routing it here would compare {commitValue} against itself.
library AtomicFlowFixtures {
    function commitValue(bytes32 _flowId, bytes32 _bundleHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _bundleHash)));
    }

    function flowId(AtomicFlowPreimage memory _preimage) internal pure returns (bytes32) {
        return keccak256(abi.encode(_preimage));
    }

    /// @dev Legs must be strictly ascending, so they are sorted here and each leg's resulting slot is
    /// returned — callers need those indices and were all repeating the same comparison.
    function twoLegPreimage(
        bytes32 _legA,
        uint256 _chainA,
        bytes32 _legB,
        uint256 _chainB,
        uint64 _deadline,
        uint256 _settlementLayerChainId
    ) internal pure returns (AtomicFlowPreimage memory preimage, uint256 indexA, uint256 indexB) {
        (indexA, indexB) = _legA < _legB ? (0, 1) : (1, 0);

        bytes32[] memory legs = new bytes32[](2);
        uint256[] memory chains = new uint256[](2);
        legs[indexA] = _legA;
        legs[indexB] = _legB;
        chains[indexA] = _chainA;
        chains[indexB] = _chainB;
        preimage = nLegPreimage(legs, chains, _deadline, _settlementLayerChainId);
    }

    /// @dev Caller owns the leg ordering: the negative shape tests start from here and then break it.
    function nLegPreimage(
        bytes32[] memory _legBundleHashes,
        uint256[] memory _legSourceChainIds,
        uint64 _deadline,
        uint256 _settlementLayerChainId
    ) internal pure returns (AtomicFlowPreimage memory preimage) {
        preimage.version = ATOMIC_FLOW_PREIMAGE_VERSION;
        preimage.deadline = _deadline;
        preimage.settlementLayerChainId = _settlementLayerChainId;
        preimage.legBundleHashes = _legBundleHashes;
        preimage.legSourceChainIds = _legSourceChainIds;
    }

    function noBundleAttributes() internal pure returns (BundleAttributes memory) {
        return
            BundleAttributes({
                executionAddress: bytes(""),
                unbundlerAddress: bytes(""),
                useFixedFee: false,
                salt: bytes32(0)
            });
    }
}

/// @notice Stands the atomic predeploys up at their canonical addresses.
/// @dev A contract, not a library, so it can use forge-std's `deployCodeTo`. The tree is optional
/// because `requireFlowFinalized` never inserts — the finalize suite needs none, and making that an
/// argument keeps the difference visible instead of leaving it an omission.
abstract contract AtomicPredeployFixture is Test {
    function _deployAtomicPredeploys(
        uint256 _l1ChainId,
        bool _withCommitmentTree
    ) internal returns (AtomicFlowManager manager, L2InteropCommitmentTree commitmentTree) {
        deployCodeTo("AtomicFlowManager.sol:AtomicFlowManager", L2_ATOMIC_FLOW_MANAGER_ADDR);
        manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        manager.initL2(_l1ChainId);

        if (_withCommitmentTree) {
            deployCodeTo("L2InteropCommitmentTree.sol:L2InteropCommitmentTree", L2_INTEROP_COMMITMENT_TREE_ADDR);
            commitmentTree = L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR);
            vm.prank(L2_COMPLEX_UPGRADER_ADDR);
            commitmentTree.initL2();
        }
    }
}
