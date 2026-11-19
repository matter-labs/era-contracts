# L2 → L1 communication

ZKsync OS exposes protocol messages and batch roots that the L1 settlement contracts bind into each
executed batch. A message becomes actionable on L1 only after its batch has been proven and executed.

## Inclusion proofs

The message-verification contracts expose inclusion checks for leaves committed by an executed batch.
On L1 these checks are implemented by `L1MessageRoot`; on L2 they are implemented by
`L2MessageVerification`:

```solidity
function proveL2LogInclusionShared(
  uint256 _chainId,
  uint256 _blockOrBatchNumber,
  uint256 _index,
  L2Log calldata _log,
  bytes32[] calldata _proof
) external view returns (bool);

function proveL2LeafInclusionShared(
  uint256 _chainId,
  uint256 _blockOrBatchNumber,
  uint256 _leafProofMask,
  bytes32 _leaf,
  bytes32[] calldata _proof
) external view returns (bool);
```

The proof connects the message or log leaf to the chain batch root recorded during execution. The
second form also supports the recursive message-root proofs used by interop. See
{protocol-docs/message-root.md} for the exact root hierarchy and proof formats.

## Withdrawals and failed deposits

Asset withdrawals carry a message from the L2 asset-routing contracts to the L1 router, nullifier, and
asset handler. Those contracts authenticate the sender, prove inclusion against the executed batch,
and enforce replay protection before releasing the asset. A failed L1 → L2 deposit uses the recorded
priority-operation result and the L1 nullifier's recovery path.

The normative asset flows and failure cases are specified in {protocol-docs/bridging.md}.
