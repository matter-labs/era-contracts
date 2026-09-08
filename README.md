# ZKsync: Smart Contracts

[![Logo](eraLogo.svg)](https://zksync.io/)

ZKsync is a layer 2 rollup that uses zero-knowledge proofs to scale Ethereum without compromising on security or
decentralization. Since it's EVM compatible (Solidity/Vyper), 99% of Ethereum projects can redeploy without refactoring
or re-auditing a single line of code.

This repository contains the ZKsync smart contracts, their deployment and upgrade tooling, and the protocol
documentation they implement. It is consumed as a git submodule by the ZK Stack server and tooling repositories.

## Repository layout

| Directory                                                       | Contents                                                                                                                                 |
| --------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| [`l1-contracts/`](./l1-contracts)                               | L1 and L2 contracts (bridgehub, bridges, chain-type manager, chain diamond, interop, ZKsync OS built-ins), Foundry deploy scripts, tests |
| [`da-contracts/`](./da-contracts)                               | Data-availability validators                                                                                                             |
| [`protocol-ops/`](./protocol-ops)                               | Rust CLI that drives the Foundry scripts for ecosystem, chain, CTM and upgrade flows, and generates governance calldata                  |
| [`tools/zksync-os-genesis-gen/`](./tools/zksync-os-genesis-gen) | Generator of the ZKsync OS genesis state (the predeployed built-in contract set)                                                         |
| [`protocol-docs/`](./protocol-docs)                             | The protocol documentation — flows, motivations, security arguments — written once and referenced from the code                          |
| [`docs/`](./docs)                                               | Design documents for the repository's own machinery (registry-driven upgrades, governance self-migration, AI review guides)              |
| [`audits/`](./audits)                                           | Audit reports                                                                                                                            |
| [`environments/`](./environments), [`configs/`](./configs)      | Per-environment addresses and genesis configuration                                                                                      |

The repository is **ZKsync OS only**: EraVM chains cannot be created, upgraded or tested from it (the EraVM
workspaces, the `zksolc` toolchain and the dual-VM tooling were removed). Audited legacy contracts are kept where
live ecosystems still depend on them.

## Documentation

- [`protocol-docs/`](./protocol-docs/README.md) is the single source of truth for the protocol: interop, atomic
  interop, bridging, the message root, and the chain lifecycle. Code comments point here instead of restating it.
- [`docs/registry-driven-upgrades.md`](./docs/registry-driven-upgrades.md) describes the upgrade model: write-once
  release / transition objects, bound executors, and the one-time bootstrap edge into it.
- Wider system specs live in the [zksync-era repository](https://github.com/matter-labs/zksync-era/blob/main/docs/src/specs/contracts).
- Working conventions for contributors and AI agents are in [`AGENTS.md`](./AGENTS.md).

## Reviewing registry-driven upgrades

Start with [the architecture](./docs/registry-driven-upgrades.md), then read
[the stage lifecycle and authority model](./docs/upgrade-stage-lifecycle.md). The
[upgrade tooling README](./l1-contracts/deploy-scripts/upgrade/README.md) explains how the
production prepare builds and submits these objects.

The current branch includes the following review surfaces:

| Review area                     | Implementation and evidence                                                                                                                                                                                                                                                                                                     |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Upgrade description             | [RegistryTypes](./l1-contracts/contracts/upgrades/registry/RegistryTypes.sol): releases, transitions, ecosystem rows, inline codehash pins, timer and L2 plan inputs.                                                                                                                                                           |
| Execution and recovery          | [CTMUpgradeExecutor](./l1-contracts/contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol) and [lifecycle tests](./l1-contracts/test/foundry/l1/unit/concrete/Upgrades/registry/CTMUpgradeLifecycle.t.sol): stages, pause holds, ecosystem authorization, executor succession and abandonment.                           |
| Separately administered proxies | [ProxyUpgradeRowLib](./l1-contracts/contracts/upgrades/registry/libraries/ProxyUpgradeRowLib.sol): explicit per-row ProxyAdmin, including ServerNotifier; application and completion checks.                                                                                                                                    |
| L2 and bootstrap payloads       | [CTMUpgradeComposer](./l1-contracts/contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol), [L2V34DelegateCalldataComposer](./l1-contracts/contracts/upgrades/L2V34DelegateCalldataComposer.sol), and [RegistryBootstrapMigration](./l1-contracts/contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol). |
| Individual-contract changes     | [RegistryIndividualUpgrade tests](./l1-contracts/test/foundry/l1/unit/concrete/Upgrades/registry/RegistryIndividualUpgrade.t.sol): facet-only, verifier-only and validator-timelock-only upgrades assert that unrelated state is unchanged.                                                                                     |
| Production proposal generation  | [v35 prepare scripts](./l1-contracts/deploy-scripts/upgrade/v35): recurring upgrades emit the three executor stage calls; other actions must be declared in the output.                                                                                                                                                         |

Security review should focus on the full authority and execution path:

- Check the source and target release/version edges, proxy identities, implementation pins,
  initialization behavior, and the code of each upgrade engine and L2 delegate/composer.
- Check every declared external action. A row under a separately owned ProxyAdmin still needs
  its administrator to act; naming the row does not grant the executor that authority.
- Review governance's recovery powers alongside the normal stages. Abandoning a pending
  lifecycle releases its hold and clears its bookkeeping; it does not reverse an executed upgrade.
- Stage 2 checks the applied L1 state. It does not prove that every chain has completed its L2
  upgrade. Bytecode publication checks likewise do not establish the safety of the bytecode.

Remaining work includes retiring duplicate script-side composition, isolating legacy bootstrap
and chain-call adapters, reducing unconditional deployment work for small patches, and making
fresh deployments establish the executor authority setup directly. Compatibility with any
already-deployed older registry schema needs an explicit migration decision; regenerated
current-source fixtures do not prove that compatibility. These items are distinct from the
implemented on-chain lifecycle and payload composition.

## Building and testing

The repository builds and tests with upstream Foundry. The pinned version is the single source of truth in
[`.github/foundry-versions.env`](./.github/foundry-versions.env); install it with:

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup --install "$(. .github/foundry-versions.env && echo "$FOUNDRY_VERSION")"
```

Then, from the repository root:

```bash
yarn build-all-contracts   # da-contracts + l1-contracts artifacts
yarn l1 test:foundry       # l1-contracts Foundry suite
yarn lint:check            # Solidity, TypeScript, Markdown, prettier and docs-anchor lints
```

Generated artifacts (`AllContractsHashes.json`, `l1-contracts/zkstack-out`, `l1-contracts/selectors`, the anvil
chain states) are checked in CI against the sources; see `AGENTS.md` for how to regenerate them. The end-to-end
upgrade and interop tests run on local Anvil chains from `l1-contracts/test/anvil-interop`.

## Contributing and security

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution guidelines and [SECURITY.md](SECURITY.md) for how to report
vulnerabilities (bug bounty on Immunefi).

## License

ZKsync contracts are distributed under the terms of the MIT license.

See [LICENSE-MIT](LICENSE-MIT) for details.

## Official Links

- [Website](https://zksync.io/)
- [GitHub](https://github.com/matter-labs)
- [ZK Credo](https://github.com/zksync/credo)
- [Twitter](https://twitter.com/zksync)
- [Twitter for Devs](https://twitter.com/zkSyncDevs)
- [Discord](https://join.zksync.dev/)
- [Mirror](https://zksync.mirror.xyz/)

## Security Disclaimer

ZKsync has been through lots of testing and audits. Although it is live, it is still in alpha state and will go
through more audits and bug bounties programs. We would love to hear our community's thoughts and suggestions about it!
It is important to state that forking it now can potentially lead to missing important security updates, critical
features, and performance improvements.
