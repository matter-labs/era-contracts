# Interop

ZKsync interop sends calls and assets from an L2 source chain to another chain through an
`InteropBundle`. The current release has two deliberately different delivery paths:

- L2 -> L2 bundles are atomic. Every send carries the `atomicBundle` attribute, commits a leg to the
  source chain's interop commitment tree, and executes on the destination only after every leg in the
  flow is proven committed before its deadline.
- L2 -> L1 bundles are non-atomic, single-call asset withdrawals. The bundle is published as an
  L2 -> L1 message and executed by `L1InteropHandler` after a message-inclusion proof.

There is no public non-atomic L2 -> L2 path, no trigger object, no automatic-execution account, and no
aliased account in this protocol version. Relayers or users submit execution proofs directly to the
destination handler.

## Reading order

1. [The interop protocol](../interop.md) — bundle and call encoding, ERC-7786 attributes, fees, send
   restrictions, handlers, replay protection, and layer-specific execution.
2. [Contract architecture](./architecture.md) — complete component map, protocol layers, source and
   destination flows, gas/retries/cancellation, proof transport, bridging, and deployment scope.
3. [Forms of finality](./forms_of_finality.md) — the proof used by each supported route and the role
   of imported roots.
4. [Atomic interop](../atomicity/README.md) — the L2 -> L2 commitment, finality, timeout, and recovery
   protocol.
5. [Message root](../message-root.md) — settlement aggregation and dependency-root import.
6. [Bridging](../bridging.md) — asset-router, native-token-vault, and recovery integration.
7. [`zksync-era` porting map](./porting-map.md) — where every source page/topic lives now and why
   retired diagrams/components are not carried as current architecture.

The [examples](./examples/README.md) describe message, asset-transfer, and multi-leg flows without
presenting a second source of truth for the contract behavior.

## End-to-end lifecycle

1. The sender previews every L2 -> L2 leg's bundle hash, constructs the shared atomic-flow preimage,
   and calls `sendMessage` or `sendBundle` with a fresh salt and the `atomicBundle` attribute. An
   L2 -> L1 withdrawal skips the preview/flow step and sends a non-atomic one-call bundle.
2. `InteropCenter` validates and funds the bundle. Direct calls preserve the requested destination
   call; an indirect asset-router call first burns the asset on the source chain and returns the actual
   destination call.
3. An L2 -> L2 leg is appended to the source chain's commitment tree. An L2 -> L1 withdrawal is sent
   through the L2-to-L1 messenger.
4. Settlement folds the relevant root into `MessageRoot`. Destination chains import dependency roots
   through the bootloader, and batch execution double-checks the imported `(root, timestamp)` values.
5. Anyone satisfying the optional execution permission submits the bundle and its proof to the
   destination handler. The handler validates destination context, proof, status, and call versions,
   marks the bundle processed before external calls, and invokes each ERC-7786 recipient.
6. If an atomic flow misses its deadline, a timeout proof makes committed source legs claimable for
   best-effort recovery instead of executable.

Execution is not automatic and atomic finality does not force all destinations to execute. It proves
that execution is allowed everywhere or recovery is allowed on committed source legs, never both.
