# Contracts architecture index

Start with [the complete system architecture](../README.md). This index links the detailed pages for
each contract domain.

- [Chain management](./chain_management/overview.md)
  - [Bridgehub](./chain_management/bridgehub.md)
  - [Chain type manager](./chain_management/chain_type_manager.md)
  - [Admin role](./chain_management/admin_role.md)
  - [Chain genesis](./chain_management/chain_genesis.md)
  - [Upgrade process](./chain_management/upgrade_process.md)
  - [Creating upgrades](./chain_management/creating_upgrades.md)
- [Bridging background](./bridging/overview.md)
  - Normative current flow: {docs/bridging.md}
- [Settlement](./settlement_contracts/zkchain_basics.md)
  - [Priority operations and L1 <-> L2 communication](./settlement_contracts/priority_queue/README.md)
  - [Data availability](./settlement_contracts/data_availability/README.md)
- [Consensus registry](./consensus/README.md)
- [ZKsync OS system hooks](../system-hooks.md)
- [ZKsync OS genesis and built-ins](../../chain-lifecycle.md#zksync-os-genesis-force-deployments-atomic-interop-built-ins)

The current interop pages live at the docs root because they cross the L1 coordination,
settlement, and bridge domains:

- {docs/interop.md}
- {docs/interop/README.md}
- {docs/atomicity/README.md}
- {docs/message-root.md}
