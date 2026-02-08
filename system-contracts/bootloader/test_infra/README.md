# Testing infrastructure for bootloader

This crate runs bootloader tests from `../tests/bootloader/bootloader_test.yul`.
It supports both:
- unit-style tests (`TEST_*`) that check pure/internal bootloader logic
- integration-style tests (`INT_TEST_*`) that mutate tx data and then let the normal bootloader transaction flow run

## Build and run

Compile contracts / preprocess bootloader:

```shell
yarn build:foundry
```

Run test infra:

```shell
cargo run
```

## Transaction fixtures for integration tests

Integration tests can access bootloader tx slots via `testing_txDataOffset(index)`.
Fixtures are loaded from `src/test_transactions/*.json` in numeric filename order (`0.json`, `1.json`, ...).

To regenerate fixture transactions:

```shell
cargo run -- --generate-transactions
```

## Expectation hooks in Yul tests

Use these helpers from `../tests/utils/test_utils.yul`:

- `testing_testWillFailWith("...")`
  - for assertion/halt-style failures
- `testing_testTransactionWillFailWith("0x...")`
  - for transaction execution failures in integration flow
  - compares expected full revert returndata hex (normalized to lowercase, optional `0x`)

This separation allows integration tests to assert tx-level revert payloads without conflating them with assertion failures.
