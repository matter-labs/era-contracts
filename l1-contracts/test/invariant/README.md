# Invariant Tests

## How to run locally

Install dependencies:

1. Clone the repository with submodules:
    ```shell
    git clone --branch nikita/invariant-tests --recurse-submodules https://github.com/matter-labs/era-contracts
    ```
1. Install Foundry ZKsync with version matching the [CI version](https://github.com/matter-labs/era-contracts/blob/eac11895e0ee700e474be828c9d7319ced9eeabe/.github/actions/l1-contracts-setup/action.yaml#L12).
1. [Yarn and contract dependencies](https://github.com/matter-labs/era-contracts/blob/eac11895e0ee700e474be828c9d7319ced9eeabe/.github/actions/l1-contracts-setup/action.yaml#L23-L34).

Nagivate to the repository root:

```shell
cd era-contracts
```

And run the tests:

```shell
yarn l1 test:invariant:l1-context
```

Or run the tests in the L2 context:

```shell
yarn l1 test:invariant:l2-context
```

Also, if you want to debug reverts:

```shell
FOUNDRY_INVARIANT_FAIL_ON_REVERT=true FOUNDRY_VERBOSITY=5 yarn l1 test:invariant:l1-context
```

## Design decisions

### Preprocessing

Currently, we do preprocessing of the source code in order to deactivate access control checks. This is because the cheatcodes aren't fully supported in Foundry ZKsync. In particular, we need cheatcodes to change the `msg.sender` in the [handler contracts](https://book.getfoundry.sh/forge/invariant-testing#handler-based-testing) which is not possible in Foundry ZKsync.

Another option would be to write different tests for L1 and L2 contracts (e.g. Bridgehub which is deployed to both L1 and L2).

## References

- [Invariant Testing](https://book.getfoundry.sh/forge/invariant-testing)
- [Cheatcodes Reference](https://book.getfoundry.sh/cheatcodes/)