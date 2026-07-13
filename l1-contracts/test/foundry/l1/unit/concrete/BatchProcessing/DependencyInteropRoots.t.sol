// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {ExecutorFacet} from "contracts/state-transition/chain-deps/facets/Executor.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {InvalidMessageRoot} from "contracts/common/L1ContractErrors.sol";
import {
    CommitBasedInteropNotSupported,
    InvalidInteropRootTimestamp,
    MessageRootIsZero
} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @dev Exposes the internal dependency-root verification for isolated unit testing. The facet
/// reads only `s.bridgehub` on this path, so the harness provides a setter for it; the MessageRoot
/// reads are mocked per test. The full execute flow is exercised by the batch-processing tests;
/// this harness isolates the `(blockNumber, root, timestamp)` tuple checks and the rolling-hash
/// wire format.
contract DependencyInteropRootsHarness is ExecutorFacet {
    constructor(uint256 _l1ChainId) ExecutorFacet(_l1ChainId) {}

    function setBridgehub(address _bridgehub) external {
        s.bridgehub = _bridgehub;
    }

    function verifyDependencyInteropRoots(InteropRoot[] memory _dependencyRoots) external view returns (bytes32) {
        return _verifyDependencyInteropRoots(_dependencyRoots);
    }
}

contract DependencyInteropRootsTest is Test {
    DependencyInteropRootsHarness internal harness;
    address internal bridgehub;
    address internal messageRoot;

    uint256 internal constant ROOT_BLOCK = 12345;
    bytes32 internal constant ROOT_HASH = keccak256("aggregated-root");
    uint256 internal constant ROOT_TIMESTAMP = 1_700_000_000;

    function setUp() public {
        harness = new DependencyInteropRootsHarness(1);
        bridgehub = makeAddr("bridgehub");
        messageRoot = makeAddr("messageRoot");
        harness.setBridgehub(bridgehub);

        vm.mockCall(bridgehub, abi.encodeWithSelector(IBridgehubBase.messageRoot.selector), abi.encode(messageRoot));
        _mockRoot(ROOT_BLOCK, ROOT_HASH, ROOT_TIMESTAMP);
    }

    function _mockRoot(uint256 _blockNumber, bytes32 _root, uint256 _timestamp) internal {
        vm.mockCall(
            messageRoot,
            abi.encodeWithSelector(IMessageRootBase.historicalRoot.selector, _blockNumber),
            abi.encode(_root)
        );
        vm.mockCall(
            messageRoot,
            abi.encodeWithSelector(IMessageRootBase.historicalRootTimestamp.selector, _blockNumber),
            abi.encode(_timestamp)
        );
    }

    function _dependencyRoot(
        uint256 _blockNumber,
        bytes32 _root,
        uint256 _timestamp
    ) internal view returns (InteropRoot[] memory roots) {
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = _root;
        roots = new InteropRoot[](1);
        roots[0] = InteropRoot({
            chainId: block.chainid,
            blockOrBatchNumber: _blockNumber,
            timestamp: _timestamp,
            sides: sides
        });
    }

    /// @notice Happy path: a matching `(blockNumber, root, timestamp)` tuple passes and the rolling
    /// hash folds the timestamp in (locking the wire format the bootloader must reproduce).
    function test_validTupleReturnsRollingHashWithTimestamp() public view {
        InteropRoot[] memory roots = _dependencyRoot(ROOT_BLOCK, ROOT_HASH, ROOT_TIMESTAMP);

        bytes32 rollingHash = harness.verifyDependencyInteropRoots(roots);

        bytes32 expected = keccak256(
            // solhint-disable-next-line func-named-parameters
            abi.encodePacked(bytes32(0), roots[0].chainId, roots[0].blockOrBatchNumber, roots[0].timestamp, ROOT_HASH)
        );
        assertEq(rollingHash, expected, "rolling hash must cover the timestamp");
    }

    /// @notice A tuple whose timestamp does not match the recorded `historicalRootTimestamp` is
    /// rejected even when the root itself is correct.
    function test_RevertWhen_TimestampMismatch() public {
        InteropRoot[] memory roots = _dependencyRoot(ROOT_BLOCK, ROOT_HASH, ROOT_TIMESTAMP + 1);

        vm.expectRevert(
            abi.encodeWithSelector(InvalidInteropRootTimestamp.selector, ROOT_TIMESTAMP, ROOT_TIMESTAMP + 1)
        );
        harness.verifyDependencyInteropRoots(roots);
    }

    /// @notice A zero claimed timestamp is rejected the same way (a chain cannot silently import a
    /// root as "timestamp-less" once the settlement layer records timestamps).
    function test_RevertWhen_TimestampZeroButRecorded() public {
        InteropRoot[] memory roots = _dependencyRoot(ROOT_BLOCK, ROOT_HASH, 0);

        vm.expectRevert(abi.encodeWithSelector(InvalidInteropRootTimestamp.selector, ROOT_TIMESTAMP, 0));
        harness.verifyDependencyInteropRoots(roots);
    }

    /// @notice A wrong root value keeps reverting with `InvalidMessageRoot` (pre-existing check).
    function test_RevertWhen_RootMismatch() public {
        bytes32 wrongRoot = keccak256("wrong-root");
        InteropRoot[] memory roots = _dependencyRoot(ROOT_BLOCK, wrongRoot, ROOT_TIMESTAMP);

        vm.expectRevert(abi.encodeWithSelector(InvalidMessageRoot.selector, ROOT_HASH, wrongRoot));
        harness.verifyDependencyInteropRoots(roots);
    }

    /// @notice A block with no recorded root keeps reverting with `MessageRootIsZero`.
    function test_RevertWhen_UnknownBlock() public {
        _mockRoot(ROOT_BLOCK + 1, bytes32(0), 0);
        InteropRoot[] memory roots = _dependencyRoot(ROOT_BLOCK + 1, ROOT_HASH, ROOT_TIMESTAMP);

        vm.expectRevert(MessageRootIsZero.selector);
        harness.verifyDependencyInteropRoots(roots);
    }

    /// @notice Foreign-chain (commit-based) imports remain unsupported.
    function test_RevertWhen_ForeignChainRoot() public {
        InteropRoot[] memory roots = _dependencyRoot(ROOT_BLOCK, ROOT_HASH, ROOT_TIMESTAMP);
        roots[0].chainId = block.chainid + 1;

        vm.expectRevert(CommitBasedInteropNotSupported.selector);
        harness.verifyDependencyInteropRoots(roots);
    }
}
