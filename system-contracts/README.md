# ZKsync Era: System Contracts

[![Logo](../eraLogo.svg)](https://zksync.io/)

ZKsync Era is a layer 2 rollup that uses zero-knowledge proofs to scale Ethereum without compromising on security or
decentralization. Since it's EVM compatible (Solidity/Vyper), 99% of Ethereum projects can redeploy without refactoring
or re-auditing a single line of code. ZKsync Era also uses an LLVM-based compiler that will eventually let developers
write smart contracts in C++, Rust and other popular languages.

## system-contracts

To keep the zero-knowledge circuits as simple as possible and enable simple extensions, we created the system contracts.
These are privileged special-purpose contracts that instantiate some recurring actions on the protocol level. Some of
the most commonly used contracts:

`ContractDeployer` This contract is used to deploy new smart contracts. Its job is to make sure that the bytecode for
each deployed contract is known. This contract also defines the derivation address. Whenever a contract is deployed, a
ContractDeployed event is emitted.

`L1Messenger` This contract is used to send messages from ZKsync to Ethereum. For each message sent, the L1MessageSent
event is emitted.

`NonceHolder` This contract stores account nonces. The account nonces are stored in a single place for efficiency (the
tx nonce and the deployment nonce are stored in a single place) and also for the ease of the operator.

`Bootloader` For greater extensibility and to lower the overhead, some parts of the protocol (e.g. account abstraction
rules) were moved to an ephemeral contract called a bootloader.

We call it ephemeral because it is not physically deployed and cannot be called, but it has a formal address that is
used on msg.sender, when it calls other contracts.

## Building

Compile the solidity and yul contracts: `yarn sc build`

Check the system contracts hashes: `yarn sc calculate-hashes:check`

Update the system contracts hashes: `yarn sc calculate-hashes:fix`

## Testing

Run the foundry tests:

```
yarn sc test:foundry
```

> Note: the EraVM behavioral test suites that depended on zksync-era-derived tooling — the hardhat spec suite running
> against anvil-zksync and the Rust bootloader test runner (`bootloader/test_infra`) — were removed when this
> repository was decoupled from zksync-era (v32+ protocol versions are ZKsync OS only). If you ever need them, they
> can be recovered from git history (`system-contracts/test`, `system-contracts/bootloader/tests`,
> `system-contracts/bootloader/test_infra`).

## Update Process

System contracts handle core functionalities and play a critical role in maintaining the integrity of our protocol. To
ensure the highest level of security and reliability, these system contracts undergo an audit before any release.

Here is an overview of the release process of the system contracts which is aimed to preserve agility and clarity on the
order of the upgrades:

### `main` branch

The `main` branch contains the latest code that is ready to be deployed into production. It reflects the most stable and
audited version of the protocol.

### `dev` branch

The `dev` branch is for active development & the latest code changes. Whenever a new PR with system contract changes is
created it should be based on the `dev` branch.

### Creating a new release

Whenever a new release is planned, a new branch named `release-vX-<name>` should be created off the `dev` branch, where
`X` represents the release version, and `<name>` is a short descriptive name for the release. The PR with the new
release should point to either the `main` branch or to the release branch with a lower version (in case the previous
branch has not been merged into `main` for some reason).

Once the audit for the release branch is complete and all the fixes from the audit are applied, we need to merge the new
changes into the `dev` branch. Once the release is final and merged into the `main` branch, the `main` branch should be
merged back into the `dev` branch to keep it up-to-date.

### Updating Unaudited Code

Since scripts, READMEs, etc., are code that is not subject to audits, these are to be merged directly into the `main`
branch. The rest of the release branches as well as the `dev` branch should merge `main` to synchronize with these
changes.

## Verification of contracts

To verify contracts deployed on a chain, ensure to firstly build all the contracts locally:

```
yarn build:foundry
```

and run the verification script afterward:

```
VERIFICATION_URL=<explorer-verification-url> yarn verify-on-explorer
```

For example, for zksync Era testnet environment it would look the following way:

```
VERIFICATION_URL=https://explorer.sepolia.era.zksync.dev/contract_verification yarn verify-on-explorer
```

## Official Links

- [Website](https://zksync.io/)
- [GitHub](https://github.com/matter-labs)
- [ZK Credo](https://github.com/zksync/credo)
- [Twitter](https://twitter.com/zksync)
- [Twitter for Devs](https://twitter.com/zkSyncDevs)
- [Discord](https://join.zksync.dev/)
- [Mirror](https://zksync.mirror.xyz/)

## Disclaimer

ZKsync Era has been through lots of testing and audits. Although it is live, it is still in alpha state and will go
through more audits and bug bounties programs. We would love to hear our community's thoughts and suggestions about it!
It is important to state that forking it now can potentially lead to missing important security updates, critical
features, and performance improvements.
