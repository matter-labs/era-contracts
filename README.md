# zkSync Era: Smart Contracts

[![Logo](eraLogo.svg)](https://zksync.io/)

zkSync Era is a layer 2 rollup that uses zero-knowledge proofs to scale Ethereum without compromising on security or
decentralization. Since it's EVM compatible (Solidity/Vyper), 99% of Ethereum projects can redeploy without refactoring
or re-auditing a single line of code. zkSync Era also uses an LLVM-based compiler that will eventually let developers
write smart contracts in C++, Rust and other popular languages.

This repository contains both L1 and L2 zkSync smart contracts. For their description see the
[system overview](docs/Overview.md).

## Disclaimer

It is used as a submodule of a private repo. Compilation and test scripts should work without additional tooling, but
others may not.

## Testing

The tests of the system contracts utilize the zkSync test node. In order to run the tests, execute the following commands in the root of the repository:

```
yarn test-node
```

It will run the test node, and you can see its logs in the output.
Then run tests in the separate terminal:

```
yarn test
```

Please note that you need to rerun the test node every time you are running the tests because, in the current version, tests will be affected by the state after the previous run.

## License

zkSync Era contracts are distributed under the terms of the MIT license.

See [LICENSE-MIT](LICENSE-MIT) for details.

## Official Links

- [Website](https://zksync.io/)
- [GitHub](https://github.com/matter-labs)
- [ZK Credo](https://github.com/zksync/credo)
- [Twitter](https://twitter.com/zksync)
- [Twitter for Devs](https://twitter.com/zkSyncDevs)
- [Discord](https://join.zksync.dev/)
- [Mirror](https://zksync.mirror.xyz/)

## Disclaimer

zkSync Era has been through lots of testing and audits. Although it is live, it is still in alpha state and will go
through more audits and bug bounties programs. We would love to hear our community's thoughts and suggestions about it!
It is important to state that forking it now can potentially lead to missing important security updates, critical
features, and performance improvements.
