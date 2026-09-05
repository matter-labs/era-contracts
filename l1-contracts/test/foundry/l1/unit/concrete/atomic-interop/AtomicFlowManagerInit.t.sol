// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AtomicFlowFixtures} from "./AtomicFlowFixtures.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {AtomicFlow, AtomicFinalityProof, ImtProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    ManagerAlreadyInitialized,
    ManagerL1ChainIdZero,
    ManagerMissingLegIndexOutOfRange,
    ManagerSettlementLayerNotL1
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {Unauthorized} from "contracts/l2-system/zksync-os/errors/SystemContractErrors.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_INTEROP_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Covers the AtomicFlowManager's L2 initialization (`initL2`) and the settlement-layer
/// gate: in this release interop legs settle on L1 only, so every flow must declare
/// `settlementLayerChainId == L1_CHAIN_ID`.
contract AtomicFlowManagerInitTest is Test {
    uint256 internal constant L1_CHAIN_ID = 5;

    AtomicFlowManager internal manager;

    function setUp() public {
        manager = new AtomicFlowManager();
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        manager.initL2(L1_CHAIN_ID);
    }

    /// @dev A minimal well-formed flow (correct flowId) declaring `_settlementLayerChainId`.
    function _flow(uint256 _settlementLayerChainId) internal pure returns (AtomicFlow memory flow) {
        bytes32[] memory legs = new bytes32[](1);
        legs[0] = keccak256("leg");
        uint256[] memory chains = new uint256[](1);
        chains[0] = 271;
        flow.preimage = AtomicFlowFixtures.nLegPreimage(legs, chains, 123, _settlementLayerChainId);
        flow.flowId = AtomicFlowFixtures.flowId(flow.preimage);
    }

    function test_initL2_setsL1ChainId() public view {
        assertEq(manager.L1_CHAIN_ID(), L1_CHAIN_ID);
    }

    function test_RevertWhen_initL2NotUpgrader() public {
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(this)));
        manager.initL2(L1_CHAIN_ID);
    }

    /// @notice Zero is the "not initialized" sentinel, so `initL2(0)` must be rejected rather than
    /// appear to succeed and leave the manager re-initializable. Fresh manager: `setUp` used the other.
    function test_RevertWhen_initL2ZeroChainId() public {
        AtomicFlowManager fresh = new AtomicFlowManager();

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(ManagerL1ChainIdZero.selector);
        fresh.initL2(0);

        assertEq(fresh.L1_CHAIN_ID(), 0, "a rejected init must leave the sentinel untouched");
    }

    function test_RevertWhen_initL2Twice() public {
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        vm.expectRevert(ManagerAlreadyInitialized.selector);
        manager.initL2(L1_CHAIN_ID);
    }

    function test_RevertWhen_finalitySettlementLayerNotL1() public {
        AtomicFlow memory flow = _flow(L1_CHAIN_ID + 1);
        AtomicFinalityProof memory finality;
        finality.flow = flow;
        finality.proofs = new ImtProof[](1);

        vm.prank(L2_INTEROP_HANDLER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(ManagerSettlementLayerNotL1.selector, L1_CHAIN_ID, L1_CHAIN_ID + 1));
        manager.requireFlowFinalized(flow.preimage.legBundleHashes[0], finality);
    }

    function test_RevertWhen_refundSettlementLayerNotL1() public {
        AtomicFlow memory flow = _flow(L1_CHAIN_ID + 1);
        // The settlement-layer check fires before the proof is ever read, so a default proof suffices.
        ImtProof memory absence;

        vm.expectRevert(abi.encodeWithSelector(ManagerSettlementLayerNotL1.selector, L1_CHAIN_ID, L1_CHAIN_ID + 1));
        manager.authorizeRefund(flow, 0, absence);
    }

    function test_RevertWhen_refundMissingLegIndexOutOfRange() public {
        AtomicFlow memory flow = _flow(L1_CHAIN_ID);
        ImtProof memory absence;

        vm.expectRevert(abi.encodeWithSelector(ManagerMissingLegIndexOutOfRange.selector, 1, 1));
        manager.authorizeRefund(flow, 1, absence);
    }
}
