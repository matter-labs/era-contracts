# Bridging architecture

The bridge architecture separates message transport from asset-specific accounting:

- `Bridgehub` and a chain's mailbox create L1 -> L2 priority operations.
- `InteropCenter` and the interop handlers carry L2 -> L2 bundles and restricted L2 -> L1
  withdrawals.
- `AssetRouter` resolves an asset ID to its handler and standardizes source `bridgeBurn` and
  destination `bridgeMint` calls.
- `NativeTokenVault` is the standard handler for native and bridged tokens. Custom assets may register
  a different handler and deployment tracker.
- `L1Nullifier` records deposits and protects withdrawal/failure-finalization paths from replay.
- `L2AssetTracker` records chain-local movement for supply observation; it is not the authorization
  boundary for minting or withdrawing.

The three active cross-layer routes are:

1. **L1 -> L2:** Bridgehub plus the L1 asset router creates a priority operation; the L2 asset router
   finalizes it.
2. **L2 -> L1:** an interop withdrawal bundle is proven to `L1InteropHandler`, then forwarded to the
   canonical L1 asset router.
3. **L2 -> L2:** an atomic interop bundle commits on the source chain and is proven to the destination
   handler before the destination asset router mints or unlocks.

See {protocol-docs/bridging.md} for the current asset IDs, registration, burn/mint, base-token,
failure-recovery, legacy-compatibility, native-token-vault, and L2-asset-tracker rules.
