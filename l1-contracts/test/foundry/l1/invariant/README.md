# Invariant Tests

The suites here live under `test/foundry/l1/`, so `yarn test:foundry` runs them, and with it CI's `test-foundry` and
`coverage-foundry` jobs on every PR.

## Suites

### `asset-router/`

Bridges one L1 token to L2 and back through the OS L2 contracts, which `SharedL2ContractL1Deployer` runs under ordinary
EVM Foundry. `L1AssetRouterActorHandler` finalizes deposits on the L2 asset router; `UserActorHandler` withdraws through
`InteropCenter.sendBundle`. `AssetRouterProperties` checks that:

- total deposits equal the bridged token's supply plus total withdrawals;
- the deposit handler never holds the bridged token.

Inline config sets `fail_on_revert = true`, so every fuzzed deposit and withdrawal must succeed too.

The contracts run unchanged: the deposit handler impersonates the aliased L1 asset router with `vm.prank`, so deposits
go through the real L2 asset-router authorization check.

## How to run locally

Build the artifacts first (see "Building Artifacts" in the repository's `AGENTS.md`), then from `l1-contracts/`:

```shell
forge test --ffi --match-path 'test/foundry/l1/invariant/*'
```

Runs and depth are set by inline config on each test contract (`/// forge-config: default.invariant.*`) and kept small,
so the suites add seconds to `yarn test:foundry`. Under the default profile inline config takes precedence over
`FOUNDRY_INVARIANT_RUNS` / `FOUNDRY_INVARIANT_DEPTH`, so for a deeper local run raise the values in the file.

To debug a failing run, including a reverted handler call:

```shell
forge test --ffi --match-path 'test/foundry/l1/invariant/*' -vvvvv
```

## References

- [Invariant Testing](https://book.getfoundry.sh/forge/invariant-testing)
- [Cheatcodes Reference](https://book.getfoundry.sh/cheatcodes/)
