# Multi-proof verification

For ZKsync OS chains, `getProofMode()` on the chain diamond reports the accepted real proof type:

| Verifier                | ZiSK disable mask | Accepted real proof        |
| ----------------------- | ----------------- | -------------------------- |
| Airbender-only verifier | 0 or 4            | Type 2: Airbender          |
| Multi-proof verifier    | 0                 | Type 5: Airbender and ZiSK |
| Multi-proof verifier    | 4                 | Type 2: Airbender          |

A multi-proof verifier rejects type 5 when ZiSK is disabled and type 2 when ZiSK is enabled. A submitted ZiSK component is never silently ignored. Airbender remains mandatory in both modes. The disable mask alone does not identify the deployed verifier; clients should use `getProofMode()` to select their encoding.

The chain admin toggles one system through `setProofSystemStatus(ProofSystem proofSystem, bool enabled)`. The shared enum identifies `Boojum = 0`, `Airbender = 1`, and `Zisk = 2`; these are system identifiers, not mask bits or proof-envelope types. Only `ProofSystem.Zisk` is writable on ZKsync OS. Boojum and Airbender are rejected, and out-of-range enum values fail ABI decoding. Mask bits are derived as `1 << uint8(proofSystem)`, preserving Boojum (`1`), Airbender (`2`), and ZiSK (`4`). Enum ordinals define the stored bit positions and must not be reordered; new systems must be appended. The diamond emits `NewDisabledProofSystems(oldMask, newMask)` on each successful setter call, including calls that retain the current value. The change takes effect immediately, including for already committed, unproved batches. Proof submitters must refresh the mode after a switch and rebuild the envelope; stale proof formats revert.

`disabledProofSystems()` returns `DisabledProofSystems { bool boojum; bool airbender; bool zisk; }`, exposing the stored disable bits by name. A false flag does not establish that the deployed verifier supports that prover; use `getProofMode()` for the accepted proof format. The underlying storage and `NewDisabledProofSystems` event remain bitmasks.

The setter still has the ABI selector of `setProofSystemStatus(uint8,bool)`, but its argument is now the enum ordinal: callers must replace the old ZiSK mask argument `4` with `ProofSystem.Zisk` (`2`). The getter keeps its selector but now returns three boolean words instead of one mask word. Regenerate client bindings and update verifier callers together when adopting this API.

Proof mode is read from the chain at verification time, so chains sharing a verifier remain independent. The executor calls `verify`, which uses the calling diamond's mask. The testnet wrapper forwards the original diamond address through `verifyForChain`; this explicit-context helper is for verification composition and does not settle batches or modify chain state. Its real-proof path follows the same mode. Empty and type-3 mock proofs remain explicit testnet bypasses and are not advertised by `getProofMode()`.

Platform clients can query the getter initially and refresh it after `NewDisabledProofSystems` or a verifier/protocol upgrade. The server must compose a standalone type-2 Airbender proof in Airbender-only mode and a type-5 envelope in multiprover mode.
