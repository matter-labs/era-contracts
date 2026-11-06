# ZKsync Era: L1 Contracts

[![Logo](../eraLogo.svg)](https://zksync.io/)

ZKsync Era is a layer 2 rollup that uses zero-knowledge proofs to scale Ethereum without compromising on security or
decentralization. Since it's EVM compatible (Solidity/Vyper), 99% of Ethereum projects can redeploy without refactoring
or re-auditing a single line of code. ZKsync Era also uses an LLVM-based compiler that will eventually let developers
write smart contracts in C++, Rust and other popular languages.

## L1 Contracts

### Building

```shell
cd era-contracts
./recompute_hashes.sh
```

### Testing

Use the following commands to run tests.

```shell
cd era-contracts
yarn l1 test:foundry
yarn l1 test:zkfoundry
```

And the following command for the fork tests.

```shell
yarn l1 test:fork
```

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
If you need to add a word to the databases of these tools please insert it into `../codespell/wordlist.txt` and `../_typos.toml`.

### Verifying contracts on L2

Some of the contracts inside the `l1-contracts` folder are predeployed on all ZK Chains. In order to verify those on explorer, build the contracts via `yarn build:foundry` and then run the following command:

```
VERIFICATION_URL=<explorer-verification-url> yarn verify-on-l2-explorer
```

For example, for ZKsync Era testnet environment it would look the following way:

```
VERIFICATION_URL=https://explorer.sepolia.era.zksync.dev/contract_verification yarn verify-on-l2-explorer
```

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
