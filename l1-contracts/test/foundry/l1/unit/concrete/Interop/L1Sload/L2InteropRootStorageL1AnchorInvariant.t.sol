// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {L1_ANCHOR_MAX_LAG, L1_BLOCK_HASH_IMPORT_ID} from "contracts/common/Config.sol";
import {StoredInteropRoot} from "contracts/common/Messaging.sol";
import {L1View} from "contracts/common/l2-helpers/L1View.sol";
import {L1AnchorStale} from "contracts/common/L1ContractErrors.sol";
import {L1AnchorNotNewer} from "contracts/interop/InteropErrors.sol";
import {L2_BOOTLOADER_ADDRESS, L2_INTEROP_ROOT_STORAGE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L1SloadMockUtils} from "./L1SloadMockUtils.sol";

/// @dev The L1 time of an L1 block in these runs: L1 records anchors in block order, so their times grow with it.
function l1Time(uint256 _blockNumber) pure returns (uint256) {
    return 1_700_000_000 + _blockNumber * 12;
}

/// @dev The freshness check every gating read runs first.
contract FreshnessProbe {
    function requireFreshAnchor() external view {
        L1View.requireFreshAnchor();
    }
}

/// @dev Imports anchors through the bootloader entry point, advances the L2 clock, and tracks the newest accepted
/// anchor.
contract L2AnchorImportHandler is Test {
    L2InteropRootStorage internal constant ROOT_STORAGE = L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR);

    uint256 public newestBlock;
    bytes32 public newestHash;
    uint256 public newestTimestamp;
    uint256 public refused;

    /// @dev Any block up to a little past the newest: older ones are refused.
    function importAnchor(uint64 _blockNumber) external {
        uint256 blockNumber = bound(_blockNumber, 0, newestBlock + 1000);
        bytes32 blockHash = keccak256(abi.encode("l1 block", blockNumber));

        if (blockNumber <= newestBlock) {
            vm.prank(L2_BOOTLOADER_ADDRESS);
            vm.expectRevert(abi.encodeWithSelector(L1AnchorNotNewer.selector, blockNumber, newestBlock));
            ROOT_STORAGE.addSingleInteropRoot(L1SloadMockUtils.anchorRoot(blockNumber, blockHash, l1Time(blockNumber)));
            ++refused;
            return;
        }
        _accept(blockNumber, blockHash);
    }

    /// @dev One of the next few hundred blocks, as an operator importing regularly does.
    function importNextAnchor(uint16 _skip) external {
        uint256 blockNumber = newestBlock + 1 + bound(_skip, 0, 300);
        _accept(blockNumber, keccak256(abi.encode("l1 block", blockNumber)));
    }

    function advanceL2Clock(uint32 _seconds) external {
        vm.warp(block.timestamp + bound(_seconds, 0, 2 * L1_ANCHOR_MAX_LAG));
    }

    function _accept(uint256 _blockNumber, bytes32 _blockHash) internal {
        L1SloadMockUtils.importAnchor(_blockNumber, _blockHash, l1Time(_blockNumber));
        newestBlock = _blockNumber;
        newestHash = _blockHash;
        newestTimestamp = l1Time(_blockNumber);
    }
}

/// @notice The L1SLOAD anchor only moves forward, carries the L1 time of its block, is never a message root, and gating
/// reads fail exactly without one or once it is past the lag in L2 block time. See {protocol-docs/l1sload.md#anchors} and
/// {protocol-docs/l1sload.md#freshness}.
contract L2InteropRootStorageL1AnchorInvariantTest is Test {
    L2InteropRootStorage internal constant ROOT_STORAGE = L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR);

    L2AnchorImportHandler internal handler;
    FreshnessProbe internal probe;
    uint256 internal lastSeenBlock;
    uint256 internal lastSeenTimestamp;

    function setUp() public {
        vm.warp(l1Time(0));
        vm.etch(L2_INTEROP_ROOT_STORAGE_ADDR, address(new L2InteropRootStorage()).code);
        handler = new L2AnchorImportHandler();
        probe = new FreshnessProbe();
        targetContract(address(handler));
    }

    function invariant_anchorIsTheNewestImport() public view {
        assertEq(ROOT_STORAGE.l1AnchorBlockNumber(), handler.newestBlock());
        assertEq(ROOT_STORAGE.l1AnchorBlockHash(), handler.newestHash());
        assertEq(ROOT_STORAGE.l1AnchorTimestamp(), handler.newestTimestamp());
    }

    /// @dev The timestamp moves with the anchor, so it never decreases either.
    function invariant_anchorNeverMovesBack() public {
        uint256 currentBlock = ROOT_STORAGE.l1AnchorBlockNumber();
        uint256 currentTimestamp = ROOT_STORAGE.l1AnchorTimestamp();
        assertGe(currentBlock, lastSeenBlock);
        assertGe(currentTimestamp, lastSeenTimestamp);
        lastSeenBlock = currentBlock;
        lastSeenTimestamp = currentTimestamp;
    }

    function invariant_anchorIsNotAMessageRoot() public view {
        StoredInteropRoot memory stored = ROOT_STORAGE.interopRoots(L1_BLOCK_HASH_IMPORT_ID, handler.newestBlock());
        assertEq(stored.root, bytes32(0));
        assertEq(stored.timestamp, 0);
    }

    function invariant_readsFailExactlyPastTheLag() public {
        uint256 anchorTimestamp = ROOT_STORAGE.l1AnchorTimestamp();
        if (anchorTimestamp == 0 || block.timestamp > anchorTimestamp + L1_ANCHOR_MAX_LAG) {
            vm.expectRevert(abi.encodeWithSelector(L1AnchorStale.selector, anchorTimestamp, block.timestamp));
        }
        probe.requireFreshAnchor();
    }
}
