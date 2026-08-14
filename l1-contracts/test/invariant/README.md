# Invariant Tests

## How to run locally

Install dependencies:

1. Clone the repository with submodules:

   ```shell
   git clone --branch nikita/invariant-tests --recurse-submodules https://github.com/matter-labs/era-contracts
   ```

1. Install upstream Foundry with the version pinned by CI.
1. [Yarn and contract dependencies](https://github.com/matter-labs/era-contracts/blob/eac11895e0ee700e474be828c9d7319ced9eeabe/.github/actions/l1-contracts-setup/action.yaml#L23-L34).

Navigate to the repository root:

```shell
cd era-contracts
```

And run the tests:

```shell
yarn l1 test:invariant:l1-context
```

Also, if you want to debug reverts:

```shell
FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_VERBOSITY=5 yarn l1 test:invariant:l1-context
```

## Design decisions

### Source handling

The runner executes the contracts unchanged. Standard Foundry cheatcodes impersonate the aliased L1 asset router,
so deposits exercise the real L2 asset-router authorization check without preprocessing or restoring source files.

### Directory structure

The surviving `l1-context` suite runs the OS L2 contract logic under ordinary EVM Foundry. The former
`l2-context` copy exercised the same invariant under Foundry-ZKsync / EraVM and was removed from the OS-only release.

## References

- [Invariant Testing](https://book.getfoundry.sh/forge/invariant-testing)
- [Cheatcodes Reference](https://book.getfoundry.sh/cheatcodes/)
