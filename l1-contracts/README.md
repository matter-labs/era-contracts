# ZKsync: L1 Contracts

[![Logo](../eraLogo.svg)](https://zksync.io/)

ZKsync is a layer 2 rollup that uses zero-knowledge proofs to scale Ethereum without compromising on security or
decentralization. Since it's EVM compatible (Solidity/Vyper), 99% of Ethereum projects can redeploy without refactoring
or re-auditing a single line of code.

This workspace holds the ZK Stack's L1 contracts, the L2 built-in contracts of ZKsync OS chains, the Foundry deploy
and upgrade scripts, and their tests. The repository is ZKsync OS only — EraVM chains cannot be created, upgraded or
tested from it (see the [root README](../README.md)).

## Layout

| Directory                                                              | Contents                                                                                                                                                                                                                                                                                                                    |
| ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`contracts/`](./contracts)                                            | The contracts: `core/` (bridgehub, message root, chain asset handler), `bridge/`, `interop/` and `atomic-interop/`, `state-transition/` (chain-type manager, chain diamond facets), `upgrades/` (upgrade engines and the `registry/` upgrade objects), `l2-upgrades/` and `l2-system/` (ZKsync OS built-ins), `governance/` |
| [`deploy-scripts/`](./deploy-scripts)                                  | Foundry scripts for ecosystem, CTM, chain and gateway deployment and for protocol upgrades (`upgrade/`), driven by [`protocol-ops`](../protocol-ops)                                                                                                                                                                        |
| [`test/foundry/`](./test/foundry)                                      | Unit and integration tests (`l1/`, `zksync-os/`, shared `mocks/`)                                                                                                                                                                                                                                                           |
| [`test/anvil-interop/`](./test/anvil-interop)                          | End-to-end tests on local Anvil chains: interop, and the v33 -> v34 (bootstrap) and v34 -> v35 (registry-driven) upgrade pipelines                                                                                                                                                                                          |
| [`test/invariant/`](./test/invariant)                                  | Invariant tests                                                                                                                                                                                                                                                                                                             |
| [`scripts/`](./scripts)                                                | Repository tooling: selectors, error-selector lint, `zkstack-out` copy, artifact regeneration, contract verification                                                                                                                                                                                                        |
| [`zkstack-out/`](./zkstack-out)                                        | Generated ABIs consumed by ZK Stack tooling (checked in CI)                                                                                                                                                                                                                                                                 |
| [`script-config/`](./script-config), [`upgrade-envs/`](./upgrade-envs) | Inputs for the deploy and upgrade scripts                                                                                                                                                                                                                                                                                   |

## Building

Install the pinned upstream Foundry (see the [root README](../README.md#building-and-testing)), then from the
repository root:

```shell
yarn l1 build:foundry
```

This runs `forge build` and refreshes `zkstack-out/` from the artifacts.

## Testing

```shell
yarn l1 test:foundry                 # Foundry unit + integration suite
yarn l1 test:hardhat:interop         # interop end-to-end on local Anvil chains
yarn l1 test:invariant:l1-context    # invariant tests
```

The upgrade pipelines run from `test/anvil-interop` (`yarn test:upgrade-v33-to-v34`, `yarn test:upgrade-v34-to-v35`);
its README covers the chain-state fixtures and port offsets. Coverage: `yarn l1 coverage:foundry` and
`yarn l1 coverage:anvil`.

## Generated artifacts

`selectors`, `zkstack-out/`, the anvil chain states and the repository-level `AllContractsHashes.json` are derived
from the sources and checked in CI. Regenerate them last, after every source change is final:

```shell
yarn l1 regen           # zkstack-out, selectors, chain states, committed registry manifest
yarn l1 errors-lint --fix
```

`AllContractsHashes.json` is regenerated through the "Update Hashes in PR" workflow (CI is its oracle);
`../recompute_hashes.sh` does the same locally and asserts the pinned Foundry version. See the repository's
`AGENTS.md` for the full order of work.

### Security Testing and Linting

Our CI/CD pipelines are equipped with multiple security tests and linting tools.
For security checks, we employ `slither`, while `solhint` is used for code linting.
It's important to note that both tools might sometimes flag issues that are not actually problematic,
known as false positives. In cases where you're confident an issue flagged by `slither` or `solhint` is a false positive,
you have the option to mark it as such.

This can be done by using specific directives provided by each tool.

For `slither`, you can find more information on marking false positives in their [triage mode documentation](https://github.com/crytic/slither/wiki/Usage#triage-mode).

Similarly, for `solhint`, guidance on configuring the linter to ignore specific issues can be found in their [README](https://github.com/protofire/solhint?tab=readme-ov-file#configure-the-linter-with-comments).

If you identify a false positive in your code, please make sure to highlight this to your colleagues during the code review process.

### Typos

We also utilize `typos` and `codespell` spell checkers to minimize the occurrence of accidental typos.
If you need to add a word to the databases of these tools please insert it into the `ignore-words-list` in `../.codespellrc` and into `../_typos.toml`.

### Verifying Contracts from Deployment Logs

We provide a script [`verify-contracts.ts`](./scripts/verify-contracts.ts) that automates contract verification from deployment logs.

#### Usage

```bash
yarn verify-contracts <log_file> --chain [stage|testnet|mainnet]
```

log_file — path to a deployment log containing forge verify-contract commands

chain — one of stage, testnet, or mainnet (default: stage)

#### Behavior

- Parses all forge verify-contract commands in the log

- Locates matching .sol sources inside l1-contracts or da-contracts

- Supports fallback mappings (e.g. VerifierFflonk → L1VerifierFflonk)

- Executes forge verify-contract from the correct project root

- If verification fails, retries with:
  - the original contract name (in case of fallback)

  - TransparentUpgradeableProxy (useful for proxy deployments)

- Redacts ETHERSCAN_API_KEY in printed commands to avoid leaking secrets

#### ZKsync Support

If a log line includes --verifier zksync, the script automatically appends the correct ZKsync verifier URL (no ETHERSCAN_API_KEY required).

For non-ZKsync logs, the script uses Etherscan-style verification and requires ETHERSCAN_API_KEY.

#### Examples

_Etherscan-style (Ethereum):_

```bash
export ETHERSCAN_API_KEY=$API_KEY
yarn verify-contracts ./deployment-logs.txt --chain mainnet
```

_ZKsync logs (no API key needed):_

```bash
yarn verify-contracts ./deployment-logs.txt --chain stage
```

If the file contains both Ethereum and ZKsync logs, it will process both successfully.
At the end of execution, the script prints a summary of verified and skipped contracts.
