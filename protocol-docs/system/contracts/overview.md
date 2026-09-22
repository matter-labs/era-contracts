# Contracts overview

`era-contracts` contains the contracts that coordinate ZK chains on L1, settle their batches, move
assets and messages between chains, and provide the EraVM execution environment. The architecture is
organized around four boundaries:

1. **L1 ecosystem contracts** — Bridgehub, chain type managers, chain diamonds, canonical bridges,
   message roots, governance, and upgrade infrastructure.
2. **Per-chain settlement contracts** — the diamond facets for batch commitment, proof verification,
   execution, priority operations, administration, and inspection.
3. **Shared L1/L2 protocol contracts** — asset routers, native token vaults, chain-asset handlers,
   interop handlers, and message verification. The L2 variants are initialized at fixed addresses and
   do not use constructor-set immutables.
4. **Execution-environment contracts** — EraVM bootloader/system contracts and ZKsync OS-specific
   genesis contracts. They share high-level settlement interfaces but not VM internals.

Continue with [the complete system map](../README.md) or use the [contract index](./README.md) to open
a domain directly.
