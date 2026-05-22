// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

import {IFlowAssetEscrow, Lock, Dispatch} from "../../interop/IFlowAssetEscrow.sol";
import {IERC7786Recipient} from "../../interop/IERC7786Recipient.sol";
import {L2_FLOW_ASSET_ESCROW_ADDR, L2_INTEROP_HANDLER_ADDR} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";

/// @notice Test-only swap pool used by the atomicity bridge test.
///
/// Holds liquidity in `bToken`. `commitSwap(flowId, bTokenAmount, dispatch)` approves and
/// locks `bTokenAmount` of `bToken` in `FlowAssetEscrow` against `flowId` and stores the
/// caller-supplied outbound `Dispatch` (typically a cross-chain bridge bundle to a recipient
/// on another chain).
///
/// `receiveMessage` (ERC-7786) is the atomic-on-arrival callback: A's interop bundle, when
/// executed on this chain, has a second call targeting the pool whose payload is the flow id.
/// `InteropHandler.executeBundle` invokes this entry, the pool's escrow then dispatches its
/// own outbound bundle in the same transaction. Result: aTokens arriving and bTokens leaving
/// are inseparable from each other — no observable state where the pool has parted with
/// bTokens but hasn't received aTokens (or vice-versa).
contract AtomicFlowSwap is IERC7786Recipient {
    IERC20 public immutable bToken;

    constructor(IERC20 _bToken) {
        bToken = _bToken;
    }

    /// @notice Pool commits its side of the swap by locking `_bTokenAmount` against `_flowId`.
    /// The caller passes the outbound `Dispatch` describing how the locked bTokens should be
    /// bridged out (e.g. to chain C via AssetRouter).
    function commitSwap(bytes32 _flowId, uint256 _bTokenAmount, Dispatch calldata _dispatch) external {
        bToken.approve(L2_FLOW_ASSET_ESCROW_ADDR, _bTokenAmount);
        Lock[] memory locks = new Lock[](1);
        locks[0] = Lock({beneficiary: address(this), token: address(bToken), amount: _bTokenAmount});
        IFlowAssetEscrow(L2_FLOW_ASSET_ESCROW_ADDR).lock(_flowId, locks, _dispatch);
    }

    /// @inheritdoc IERC7786Recipient
    /// @dev Invoked by `InteropHandler.executeBundle` as the second call in A's bundle —
    /// runs after `AssetRouter.finalizeDeposit` has minted aTokens to this pool. The payload
    /// is the abi-encoded flow id; the pool then triggers its own outbound dispatch via the
    /// escrow. The escrow's `dispatchToInteropCenter` gate detects the simulation context
    /// (via `Simulator.isSimulating`) so the same path works during phase 2 (simulate, all
    /// rolled back) and phase 5 (real execute, atomic with the inbound bundle).
    function receiveMessage(
        bytes32 /* receiveId */,
        bytes calldata /* sender */,
        bytes calldata _payload
    ) external payable returns (bytes4) {
        if (msg.sender != L2_INTEROP_HANDLER_ADDR) revert Unauthorized(msg.sender);
        bytes32 flowId = abi.decode(_payload, (bytes32));
        IFlowAssetEscrow(L2_FLOW_ASSET_ESCROW_ADDR).dispatchToInteropCenter(flowId);
        return IERC7786Recipient.receiveMessage.selector;
    }
}
