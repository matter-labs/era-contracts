# Overview

Ethereum's future is rollup-centric. This means breaking with the current paradigm of isolated EVM chains to infrastructure that is focused on an ecosystem of interconnected zkEVMs/zkVMs, (which we name ZK chain). This ecosystem will be grounded on Ethereum, requiring the appropriate L1 smart contracts. Here we outline our ZK Stack approach for these contracts, their interfaces, the needed changes to the existing architecture, as well as future features to be implemented.

If you want to know more about ZK chains, check this [blog post](https://blog.matter-labs.io/introduction-to-hyperchains-fdb33414ead7), or go through [our docs](https://era.zksync.io/docs/reference/concepts/hyperscaling.html).

This document will assume the reader already knows how rollups (esp. zkSync Era) work.

## Long term goal

We want to create a system where:

- ZK chains should be launched permissionlessly within the ecosystem.
- Interop is seamless and enables unified liquidity for assets across the ecosystem.
- Multi-chain smart contracts need to be easy to develop, which means easy access to traditional bridges, and other supporting architecture.


ZKsync Era is a permissionless general-purpose ZK rollup. Similar to many L1 blockchains and sidechains it enables
deployment and interaction with Turing-complete smart contracts.

- L2 smart contracts are executed on a zkEVM.
- zkEVM bytecode is different from the L1 EVM.
- There is a Solidity and Vyper compilers for L2 smart contracts.
- There is a standard way to pass messages between L1 and L2. That is a part of the protocol.
- There is no escape hatch mechanism yet, but there will be one.

All data that is needed to restore the L2 state are also pushed on-chain. There are two approaches, publishing inputs of
L2 transactions on-chain and publishing the state transition diff. ZKsync follows the second option.

See the [documentation](https://era.zksync.io/docs/dev/fundamentals/rollups.html) to read more!
