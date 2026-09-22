# Bridgehub

`L1Bridgehub` is the ecosystem registry and the public L1 entry point for chain creation and L1 -> L2
transactions. It records:

- chain ID -> chain diamond and chain type manager;
- chain ID -> base-token asset ID;
- chain ID -> settlement-layer chain ID;
- registered CTMs and settlement layers;
- the canonical asset router, message root, chain asset handler, and chain registration sender.

## Chain creation

`createNewChain` is restricted to the Bridgehub owner or admin. It validates that the chain ID is new,
records the CTM/base-token/settlement data, asks the CTM to deploy the diamond, registers the result,
and adds the chain to the L1 `MessageRoot`. ZKsync OS chains also seed their batch-0 chain root. The
complete ordering and guards are in {protocol-docs/chain-lifecycle.md#chain-creation-createnewchain}.

## L1 -> L2 requests

- `requestL2TransactionDirect` routes a caller-funded request to the target chain's mailbox.
- `requestL2TransactionTwoBridges` first calls the L1 asset router/handler to lock or burn an asset,
  then submits the returned destination calldata and required mint value to the mailbox.
- Service-transaction entry points are reserved for protocol components such as chain registration.

The Bridgehub does not itself mint bridged assets. It authenticates the route and coordinates the
asset router with the destination chain. See {protocol-docs/bridging.md}.

## L2 and settlement-layer variants

A fixed-address L2 Bridgehub implements the shared registry interface needed by L2 protocol contracts.
Generic settlement-layer relay entry points are also retained. In the current release all supported
chains settle on L1 and new settlement-layer migrations are disabled; see
[settlement-layer status](../gateway/README.md).
