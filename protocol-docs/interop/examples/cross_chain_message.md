# Cross-chain message

Suppose a controller on chain A must open registration in a recipient contract on chain B. The
controller sends one direct ERC-7786 message whose payload encodes the recipient's `openRegistration`
call.

## Source-chain preparation

1. Encode the recipient as an ERC-7930 EVM address containing chain B's chain ID and recipient address.
2. Choose an unused `interopBundleSalt` for the controller.
3. Call `previewMessageHash` through `eth_call` with the recipient, payload, and all non-atomic
   attributes. The quoter always reverts with `InteropPreviewHash(bundleHash)`; decode that revert.
4. Build an `AtomicFlowPreimage` with version `0x02`, the previewed hash, chain A as its source, and
   chain B as its destination. For a one-leg flow, the strictly ascending bundle-hash requirement is
   trivially satisfied. Choose a deadline in the L1 settlement-layer timestamp domain that leaves time
   for chain B to accept the bundle and settle ({protocol-docs/atomicity/acceptance.md#liveness}).
5. Call `sendMessage` with the same recipient, payload, and salt plus the `atomicBundle` attribute.
   The attribute contains the preimage and `lowNullifierIndex`. Any change that affects bundle
   construction changes the hash and makes the
   manager reject the send, rolling back the whole transaction.

`sendMessage` wraps the call in an `InteropBundle`, emits one ERC-7786 `MessageSent` and one
`InteropBundleSent`, and commits the leg through `AtomicFlowManager`. As this is chain A's only step in
the flow, it also inserts chain A's participation value. It does not create a trigger or schedule
destination execution.

## Destination acceptance and execution

Anyone then calls `L2InteropHandler.acceptAtomicBundle(bundle, preimage, lowNullifierIndex)` on chain B
with the full bundle. This records the leg as `Accepted` there and, as chain B's only step, inserts
chain B's participation value ({protocol-docs/atomicity/acceptance.md#accepting-a-leg}).

After both chains' commitment-tree roots settle and are imported, a relayer calls
`L2InteropHandler.executeAtomicBundle(bundle, finalityProof)` on chain B. The finality proof shows that
chains A and B each inserted their participation value before the deadline. The handler then calls
`recipient.receiveMessage(receiveId, sender, payload)` and requires the ERC-7786 selector in return.

The recipient should authenticate the `sender` interoperable address and reject duplicate
application-level actions if its own semantics require that. Protocol replay protection prevents the
same bundle call from executing twice, but it does not define the recipient's business rules.

If `executionAddress` is empty, anyone may submit the proof. Setting it restricts who can drive the
bundle; it does not change the authenticated cross-chain sender delivered to the recipient.
