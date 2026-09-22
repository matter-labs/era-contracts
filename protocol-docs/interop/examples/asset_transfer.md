# Cross-chain asset transfer

An L2 -> L2 token transfer is an indirect interop call. The user's call starter targets the canonical
L2 asset router and carries the `indirectCall` attribute. During bundle construction,
`InteropCenter` invokes `L2AssetRouter.initiateIndirectCall` on the source chain. The router burns or
locks the asset through its registered handler and returns the actual destination call, normally an
ERC-7786 `finalizeDeposit` payload for the destination asset router.

The amount transferred is encoded in that returned payload. An indirect call must set
`interopCallValue` to zero; source-side native value needed by the router is carried separately as
`indirectCallMessageValue`. The latter contributes to the exact `msg.value` required by the send.

As with every L2 -> L2 transfer, the caller first previews the bundle hash, includes it in an atomic
flow preimage, and repeats the same inputs in `sendBundle` with the `atomicBundle` attribute. At the
destination, `executeAtomicBundle` proves the flow and delivers the router-produced call. The
destination asset router validates the ERC-7786 sender and finalizes the mint through the registered
asset handler.

If the flow times out, the source `AtomicFlowManager` passes the stored destination and call data to
`L2AssetRouter.recoverAtomicCall`. The router recognizes the historical `finalizeDeposit` encoding and
uses the asset handler's failed-transfer path to restore the original caller's balance. Recovery is
best-effort and a refund claim is all-or-nothing if an attempted recovery reverts; see
{protocol-docs/atomicity/recovery.md}.

## L2 -> L1 withdrawal

The L1 route is intentionally different. It is non-atomic and supports exactly one indirect,
zero-`interopCallValue` asset-router call. `InteropCenter` publishes the bundle as an L2 -> L1 message;
after settlement, `L1InteropHandler.executeBundle` proves the message and invokes only the canonical
L1 asset router. L2 -> L1 bundles pay no interop protocol fee and cannot use `atomicBundle`.

The complete burn/mint and failed-transfer accounting is documented in {protocol-docs/bridging.md}.
