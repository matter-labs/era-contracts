// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L1Reads} from "contracts/common/l2-helpers/L1Reads.sol";
import {L1AnchorStale, L1SloadFailed, L1SloadInvalidKeyCount} from "contracts/common/L1ContractErrors.sol";
import {L1SLOAD_CALL_GAS, L1SLOAD_MAX_ANCHOR_AGE, L1SLOAD_MAX_KEYS} from "contracts/common/Config.sol";
import {L1SLOAD_PRECOMPILE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L1SloadMockUtils} from "./L1SloadMockUtils.sol";

contract L1ReadsHarness {
    function anchor() external view returns (uint256, bytes32, uint256) {
        return L1Reads.anchor();
    }

    function requireFresh(uint256 _maxAge) external view {
        L1Reads.requireFresh(_maxAge);
    }

    function read(address _l1Contract, bytes32 _key) external view returns (bytes32) {
        return L1Reads.read(_l1Contract, _key);
    }

    function read(address _l1Contract, bytes32[] memory _keys) external view returns (bytes32[] memory) {
        return L1Reads.read(_l1Contract, _keys);
    }

    function mappingSlot(bytes32 _slot, bytes32 _key) external pure returns (bytes32) {
        return L1Reads.mappingSlot(_slot, _key);
    }
}

/// @dev A contract whose storage layout `mappingSlot` is checked against.
contract MappingLayout {
    uint256 internal padding;
    mapping(uint256 chainId => mapping(uint256 peerChainId => bool)) internal allowed;

    function allow(uint256 _chainId, uint256 _peerChainId) external {
        allowed[_chainId][_peerChainId] = true;
    }
}

/// @notice `L1Reads` against {MockL1SloadPrecompile}, which models the precompile's failures but not its proofs.
/// See {protocol-docs/l1sload.md}.
contract L1ReadsTest is Test {
    uint256 internal constant ANCHORED_AT = 1_700_000_000;
    bytes32 internal constant ANCHOR_HASH = keccak256("l1-block-100");

    L1ReadsHarness internal harness;
    address internal l1Contract = makeAddr("l1Contract");

    function setUp() public {
        L1SloadMockUtils.install();
        harness = new L1ReadsHarness();
        vm.warp(ANCHORED_AT);
    }

    function test_anchor() public {
        (uint256 blockNumber, bytes32 blockHash, uint256 timestamp) = harness.anchor();
        assertEq(blockNumber, 0);
        assertEq(blockHash, bytes32(0));
        assertEq(timestamp, 0);

        L1SloadMockUtils.importAnchor(100, ANCHOR_HASH, ANCHORED_AT);
        (blockNumber, blockHash, timestamp) = harness.anchor();
        assertEq(blockNumber, 100);
        assertEq(blockHash, ANCHOR_HASH);
        assertEq(timestamp, ANCHORED_AT);
    }

    /// @dev With `maxAge = L1SLOAD_MAX_ANCHOR_AGE`, `requireFresh` passes exactly when the precompile reads.
    function testFuzz_freshness(uint256 _age, uint256 _maxAge) public {
        L1SloadMockUtils.importAnchor(100, ANCHOR_HASH, ANCHORED_AT);
        uint256 age = bound(_age, 0, 10 * L1SLOAD_MAX_ANCHOR_AGE);
        uint256 maxAge = bound(_maxAge, 0, L1SLOAD_MAX_ANCHOR_AGE);
        vm.warp(ANCHORED_AT + age);

        if (age > maxAge) {
            vm.expectRevert(abi.encodeWithSelector(L1AnchorStale.selector, ANCHORED_AT, ANCHORED_AT + age));
        }
        harness.requireFresh(maxAge);

        if (age > L1SLOAD_MAX_ANCHOR_AGE) {
            vm.expectRevert(abi.encodeWithSelector(L1AnchorStale.selector, ANCHORED_AT, ANCHORED_AT + age));
            harness.requireFresh(L1SLOAD_MAX_ANCHOR_AGE);
            vm.expectRevert(abi.encodeWithSelector(L1SloadFailed.selector, l1Contract));
        } else {
            harness.requireFresh(L1SLOAD_MAX_ANCHOR_AGE);
        }
        harness.read(l1Contract, bytes32(0));
    }

    /// @dev L2 time may trail L1 time, so an anchor recorded after the current L2 block counts as fresh.
    function test_requireFresh_anchorAheadOfL2Time() public {
        L1SloadMockUtils.importAnchor(100, ANCHOR_HASH, ANCHORED_AT + 1 days);
        harness.requireFresh(0);
    }

    function test_revertWhen_noAnchor() public {
        vm.expectRevert(abi.encodeWithSelector(L1AnchorStale.selector, 0, ANCHORED_AT));
        harness.requireFresh(type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(L1SloadFailed.selector, l1Contract));
        harness.read(l1Contract, bytes32(0));
    }

    function test_read() public {
        L1SloadMockUtils.importAnchor(100, ANCHOR_HASH, ANCHORED_AT);
        bytes32[] memory keys = new bytes32[](L1SLOAD_MAX_KEYS);
        for (uint256 i = 0; i < keys.length; ++i) {
            keys[i] = keccak256(abi.encode(i));
            L1SloadMockUtils.setL1Storage(l1Contract, keys[i], bytes32(i + 1));
        }

        bytes32[] memory values = harness.read(l1Contract, keys);

        assertEq(values.length, keys.length);
        for (uint256 i = 0; i < keys.length; ++i) {
            assertEq(values[i], bytes32(i + 1));
        }
        assertEq(harness.read(l1Contract, keys[3]), bytes32(uint256(4)));
    }

    function test_revertWhen_invalidKeyCount() public {
        L1SloadMockUtils.importAnchor(100, ANCHOR_HASH, ANCHORED_AT);

        vm.expectRevert(abi.encodeWithSelector(L1SloadInvalidKeyCount.selector, 0));
        harness.read(l1Contract, new bytes32[](0));

        vm.expectRevert(abi.encodeWithSelector(L1SloadInvalidKeyCount.selector, L1SLOAD_MAX_KEYS + 1));
        harness.read(l1Contract, new bytes32[](L1SLOAD_MAX_KEYS + 1));
    }

    /// @dev A failed precompile call consumes the gas passed to it, which `L1Reads` caps.
    function test_failedReadCostsAtMostTheCap() public {
        uint256 gasBefore = gasleft();
        vm.expectRevert(abi.encodeWithSelector(L1SloadFailed.selector, l1Contract));
        harness.read(l1Contract, bytes32(0));
        assertLt(gasBefore - gasleft(), L1SLOAD_CALL_GAS + 20_000);
    }

    /// @dev A precompile answering with the wrong length is a failed read, not a short answer.
    function test_revertWhen_outputLengthIsWrong() public {
        // STOP: succeeds with empty output.
        vm.etch(L1SLOAD_PRECOMPILE_ADDR, hex"00");
        vm.expectRevert(abi.encodeWithSelector(L1SloadFailed.selector, l1Contract));
        harness.read(l1Contract, bytes32(0));
    }

    /// @dev Nested mappings resolve to the slot Solidity stores the value at.
    function testFuzz_mappingSlot(uint256 _chainId, uint256 _peerChainId) public {
        MappingLayout layout = new MappingLayout();
        layout.allow(_chainId, _peerChainId);

        bytes32 slot = harness.mappingSlot(
            harness.mappingSlot(bytes32(uint256(1)), bytes32(_chainId)),
            bytes32(_peerChainId)
        );
        assertEq(vm.load(address(layout), slot), bytes32(uint256(1)));
    }
}
