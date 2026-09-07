# Multi-proof verification

For ZKsync OS chains, `getProofMode()` on the chain diamond reports the accepted real proof type:

| Verifier                | ZiSK disable mask | Accepted real proof        |
| ----------------------- | ----------------- | -------------------------- |
| Airbender-only verifier | 0 or 4            | Type 2: Airbender          |
| Multi-proof verifier    | 0                 | Type 5: Airbender and ZiSK |
| Multi-proof verifier    | 4                 | Type 2: Airbender          |

A multi-proof verifier rejects type 5 when ZiSK is disabled and type 2 when ZiSK is enabled. A submitted ZiSK component is never silently ignored. Airbender remains mandatory in both modes. The disable mask alone does not identify the deployed verifier; clients should use `getProofMode()` to select their encoding.

The chain admin changes the mask through `setDisabledProofSystems(uint8)`. Only 0 and 4 are allowed. The diamond emits `NewDisabledProofSystems(oldMask, newMask)` on each successful setter call, including calls that retain the current value. The change takes effect immediately, including for already committed, unproved batches. Proof submitters must refresh the mode after a switch and rebuild the envelope; stale proof formats revert.

Proof mode is read from the chain at verification time, so chains sharing a verifier remain independent. The executor calls `verify`, which uses the calling diamond's mask. The testnet wrapper forwards the original diamond address through `verifyForChain`; this explicit-context helper is for verification composition and does not settle batches or modify chain state. Its real-proof path follows the same mode. Empty and type-3 mock proofs remain explicit testnet bypasses and are not advertised by `getProofMode()`.

Platform clients can query the getter initially and refresh it after `NewDisabledProofSystems` or a verifier/protocol upgrade. The server must compose a standalone type-2 Airbender proof in Airbender-only mode and a type-5 envelope in multiprover mode.
