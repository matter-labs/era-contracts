# Chain genesis

New supported chains are created by `L1Bridgehub.createNewChain`. The caller supplies the chain ID,
CTM, base-token asset ID and admin. Bridgehub records the chain's L1 settlement layer and delegates
deployment to the CTM, passing only the chain ID and admin; everything else is read from the CTM's
current release (`currentRelease`) and the Bridgehub.

The CTM deploys the diamond and runs `DiamondInit`, which installs the release's facets and
initializes shared diamond storage including the verifier configuration, admin, fee parameters,
base-token asset ID, priority structure, and native token vault reference. The genesis upgrade
transaction initializes the L2 chain ID and force-deploys the built-in L2 protocol contracts required
by that execution environment.

Bridgehub then registers the diamond and base-token asset, creates the chain's leaf in `MessageRoot`,
and seeds batch 0 for the new ZKsync OS chain.

Built-in L2 protocol addresses are defined centrally in `L2ContractAddresses.sol`; they include the L2
Bridgehub, asset router, native token vault, message-root/verification contracts, interop center and
handler, and—on ZKsync OS—the atomic-flow manager and indexed commitment tree. L2 implementations have
no constructors or immutables and are initialized through `initL2`/upgrade calls.

For the exact transaction ordering, invariants, fixed addresses, and differences between new and
upgraded chains, see [Chain lifecycle](../../../chain-lifecycle.md).
The scripts and inputs that perform chain creation, and the deployment of the Bridgehub and CTM
it depends on, are described in [Deploying a new ecosystem](../../../ecosystem-deployment.md).
