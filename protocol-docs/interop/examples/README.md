# Interop examples

These examples illustrate how to compose the current protocol. They intentionally omit ABI encoding
and proof-construction code; the normative entry points and restrictions live in
{protocol-docs/interop.md}.

- [Cross-chain message](./cross_chain_message.md) — a single ERC-7786 call in a one-leg atomic flow.
- [Asset transfer](./asset_transfer.md) — an indirect call through the L2 asset router.
- [Atomic multi-leg flow](./cross_chain_swap.md) — coordinating bundles from more than one source.

Every L2 -> L2 example follows the same preparation sequence: choose a fresh sender salt, preview each
bundle hash with the matching `preview*Hash` quoter, build the canonical flow preimage, then perform the
real sends with identical call/bundle inputs plus the `atomicBundle` attribute.
