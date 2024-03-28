# zkSync Era: L1 Contracts

[![Logo](../eraLogo.svg)](https://zksync.io/)

zkSync Era is a layer 2 rollup that uses zero-knowledge proofs to scale Ethereum without compromising on security or
decentralization. Since it's EVM compatible (Solidity/Vyper), 99% of Ethereum projects can redeploy without refactoring
or re-auditing a single line of code. zkSync Era also uses an LLVM-based compiler that will eventually let developers
write smart contracts in C++, Rust and other popular languages.

## L1 Contracts

### Building

Compile the solidity and yul contracts: `yarn l1 build`

### Testing

To run unit tests, execute `yarn l1 test`.

Similarly, to run tests in Foundry execute `yarn l1 test:foundry`.

To run the fork test, use `yarn l1 test:fork`

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
