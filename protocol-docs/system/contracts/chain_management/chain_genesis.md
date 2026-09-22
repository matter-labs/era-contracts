# Chain genesis

New supported chains are created by `L1Bridgehub.createNewChain`. The caller supplies the chain ID,
CTM, base-token asset ID, admin, initialization data, and factory dependencies. Bridgehub records the
chain's L1 settlement layer and delegates deployment to the CTM.

The CTM deploys the diamond and runs `DiamondInit`, which initializes shared diamond storage including
the verifier configuration, admin, fee parameters, base-token asset ID, priority structure, and native
token vault reference. The genesis upgrade transaction initializes the L2 chain ID and force-deploys
the built-in L2 protocol contracts required by that execution environment.

Bridgehub then registers the diamond and base-token asset, creates the chain's leaf in `MessageRoot`,
and seeds batch 0 for the new ZKsync OS chain.

Built-in L2 protocol addresses are defined centrally in `L2ContractAddresses.sol`; they include the L2
Bridgehub, asset router, native token vault, message-root/verification contracts, interop center and
handler, and—on ZKsync OS—the atomic-flow manager and indexed commitment tree. L2 implementations have
no constructors or immutables and are initialized through `initL2`/upgrade calls.

For the exact transaction ordering, invariants, fixed addresses, and differences between new and
upgraded chains, see {protocol-docs/chain-lifecycle.md}.
