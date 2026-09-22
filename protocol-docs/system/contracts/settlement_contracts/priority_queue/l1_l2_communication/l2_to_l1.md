# L2 → L1 communication

ZKsync OS exposes protocol messages and batch roots that the L1 settlement contracts bind into each
executed batch. A message becomes actionable on L1 only after its batch has been proven and executed.

## Inclusion proofs

The chain diamond exposes inclusion checks for the leaves committed by an executed batch:

```solidity
function proveL2LogInclusion(
  uint256 _chainId,
  uint256 _batchNumber,
  uint256 _index,
  L2Log calldata _log,
  bytes32[] calldata _proof
) external view returns (bool);

function proveL2LeafInclusion(
  uint256 _chainId,
  uint256 _batchNumber,
  uint256 _mask,
  bytes32 _leaf,
  bytes32[] calldata _proof
) external view returns (bool);
```

The proof connects the message or log leaf to the chain batch root recorded during execution. The
second form also supports nested message-root proofs used by interop and dormant settlement-layer
relaying. See {protocol-docs/message-root.md} for the exact root hierarchy and proof formats.

## Withdrawals and failed deposits

Asset withdrawals carry a message from the L2 asset-routing contracts to the L1 router, nullifier, and
asset handler. Those contracts authenticate the sender, prove inclusion against the executed batch,
and enforce replay protection before releasing the asset. A failed L1 → L2 deposit uses the recorded
priority-operation result and the L1 nullifier's recovery path.

The normative asset flows and failure cases are specified in {protocol-docs/bridging.md}.
