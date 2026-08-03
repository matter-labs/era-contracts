// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {InvalidMessageRoot} from "contracts/common/L1ContractErrors.sol";
import {
    CommitBasedInteropNotSupported,
    InvalidInteropRootTimestamp,
    MessageRootIsZero
} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @dev Exposes the internal dependency-root verification for isolated unit testing (the facet reads
/// only `s.bridgehub` on this path, hence the setter). Isolates the `(blockNumber, root, timestamp)`
/// tuple checks and the rolling-hash wire format against a REAL `L1MessageRoot` populated through its
/// production entry points — no mocked root values; the full execute flow is covered by the
/// batch-processing tests.
contract DependencyInteropRootsHarness is ExecutorFacet {
    function setBridgehub(address _bridgehub) external {
        s.bridgehub = _bridgehub;
    }

    function verifyDependencyInteropRoots(InteropRoot[] memory _dependencyRoots) external view returns (bytes32) {
        return _verifyDependencyInteropRoots(_dependencyRoots);
    }
}

contract DependencyInteropRootsTest is Test {
    DependencyInteropRootsHarness internal harness;
    L1MessageRoot internal messageRoot;
    address internal bridgehub;
    address internal chainAssetHandler;
    address internal chainSender;

    uint256 internal constant CHAIN_ID = 271;
    uint256 internal constant BLOCK_1 = 100;
    uint256 internal constant TIMESTAMP_1 = 1_700_000_100;
    uint256 internal constant BLOCK_2 = 200;
    uint256 internal constant TIMESTAMP_2 = 1_700_000_200;

    bytes32 internal root1;
    bytes32 internal root2;

    function setUp() public {
        bridgehub = makeAddr("bridgehub");
        chainAssetHandler = makeAddr("chainAssetHandler");
        chainSender = makeAddr("chainSender");

        harness = new DependencyInteropRootsHarness();
        harness.setBridgehub(bridgehub);

        // A real L1MessageRoot, wired to the mocked bridgehub for ACL only; every root/timestamp it
        // serves below is produced by its production write paths.
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(new uint256[](0))
        );
        messageRoot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(bridgehub, 1, chainAssetHandler)),
                    address(uint160(1)),
                    abi.encodeCall(L1MessageRoot.initialize, ())
                )
            )
        );
        vm.mockCall(bridgehub, abi.encodeWithSelector(IBridgehubBase.messageRoot.selector), abi.encode(messageRoot));
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, CHAIN_ID),
            abi.encode(chainSender)
        );

        // Register a chain and settle two batches in two distinct blocks, producing two real
        // historical `(blockNumber, root, timestamp)` tuples.
        vm.prank(bridgehub);
        messageRoot.addNewChain(CHAIN_ID, 0);

        vm.roll(BLOCK_1);
        vm.warp(TIMESTAMP_1);
        vm.prank(chainSender);
        messageRoot.addChainBatchRootV32(CHAIN_ID, 1, keccak256("chain-batch-root-1"));
        root1 = messageRoot.historicalRoot(BLOCK_1).root;

        vm.roll(BLOCK_2);
        vm.warp(TIMESTAMP_2);
        vm.prank(chainSender);
        messageRoot.addChainBatchRootV32(CHAIN_ID, 2, keccak256("chain-batch-root-2"));
        root2 = messageRoot.historicalRoot(BLOCK_2).root;

        assertTrue(root1 != bytes32(0) && root2 != bytes32(0) && root1 != root2, "distinct real roots recorded");
    }

    function _dependencyRoot(
        uint256 _blockNumber,
        bytes32 _root,
        uint256 _timestamp
    ) internal view returns (InteropRoot memory root) {
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = _root;
        root = InteropRoot({
            chainId: block.chainid,
            blockOrBatchNumber: _blockNumber,
            timestamp: _timestamp,
            sides: sides
        });
    }

    function _rollingHashStep(bytes32 _previous, InteropRoot memory _root) internal pure returns (bytes32) {
        return
            keccak256(
                // solhint-disable-next-line func-named-parameters
                abi.encodePacked(_previous, _root.chainId, _root.blockOrBatchNumber, _root.timestamp, _root.sides)
            );
    }

    /// @notice Happy path: a matching `(blockNumber, root, timestamp)` tuple passes and the rolling
    /// hash folds the timestamp in (locking the wire format the bootloader must reproduce).
    function test_validTupleReturnsRollingHashWithTimestamp() public view {
        InteropRoot[] memory roots = new InteropRoot[](1);
        roots[0] = _dependencyRoot(BLOCK_1, root1, TIMESTAMP_1);

        bytes32 rollingHash = harness.verifyDependencyInteropRoots(roots);

        assertEq(rollingHash, _rollingHashStep(bytes32(0), roots[0]), "rolling hash must cover the timestamp");
    }

    /// @notice Multiple dependency roots verify in order and chain into one rolling hash.
    function test_multipleRootsChainIntoRollingHash() public view {
        InteropRoot[] memory roots = new InteropRoot[](2);
        roots[0] = _dependencyRoot(BLOCK_1, root1, TIMESTAMP_1);
        roots[1] = _dependencyRoot(BLOCK_2, root2, TIMESTAMP_2);

        bytes32 rollingHash = harness.verifyDependencyInteropRoots(roots);

        bytes32 expected = _rollingHashStep(_rollingHashStep(bytes32(0), roots[0]), roots[1]);
        assertEq(rollingHash, expected, "rolling hash must chain over all roots in order");
    }

    /// @notice A tuple whose timestamp does not match the recorded one is rejected even when the
    /// root itself is correct.
    function test_RevertWhen_TimestampMismatch() public {
        InteropRoot[] memory roots = new InteropRoot[](1);
        roots[0] = _dependencyRoot(BLOCK_1, root1, TIMESTAMP_1 + 1);

        vm.expectRevert(abi.encodeWithSelector(InvalidInteropRootTimestamp.selector, TIMESTAMP_1, TIMESTAMP_1 + 1));
        harness.verifyDependencyInteropRoots(roots);
    }

    /// @notice A zero claimed timestamp is rejected because it does not match the recorded timestamp.
    function test_RevertWhen_TimestampZeroButRecorded() public {
        InteropRoot[] memory roots = new InteropRoot[](1);
        roots[0] = _dependencyRoot(BLOCK_1, root1, 0);

        vm.expectRevert(abi.encodeWithSelector(InvalidInteropRootTimestamp.selector, TIMESTAMP_1, 0));
        harness.verifyDependencyInteropRoots(roots);
    }

    /// @notice A wrong root value keeps reverting with `InvalidMessageRoot` (pre-existing check).
    function test_RevertWhen_RootMismatch() public {
        InteropRoot[] memory roots = new InteropRoot[](1);
        roots[0] = _dependencyRoot(BLOCK_1, root2, TIMESTAMP_1);

        vm.expectRevert(abi.encodeWithSelector(InvalidMessageRoot.selector, root1, root2));
        harness.verifyDependencyInteropRoots(roots);
    }

    /// @notice A block with no recorded root keeps reverting with `MessageRootIsZero`.
    function test_RevertWhen_UnknownBlock() public {
        InteropRoot[] memory roots = new InteropRoot[](1);
        roots[0] = _dependencyRoot(BLOCK_2 + 1, root1, TIMESTAMP_1);

        vm.expectRevert(MessageRootIsZero.selector);
        harness.verifyDependencyInteropRoots(roots);
    }

    /// @notice Foreign-chain (commit-based) imports remain unsupported.
    function test_RevertWhen_ForeignChainRoot() public {
        InteropRoot[] memory roots = new InteropRoot[](1);
        roots[0] = _dependencyRoot(BLOCK_1, root1, TIMESTAMP_1);
        roots[0].chainId = block.chainid + 1;

        vm.expectRevert(CommitBasedInteropNotSupported.selector);
        harness.verifyDependencyInteropRoots(roots);
    }
}
