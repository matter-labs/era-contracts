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

Integration tests can access bootloader tx slots via `testing_txDataOffset(index)`, and the
description slot the server writes (`txMeta`) via `testing_txDescriptionPtr(index)`.
Fixtures are loaded from `src/test_transactions/*.json` in numeric filename order (`0.json`, `1.json`, ...):

- `0.json`, `1.json` — L2 transactions (EIP-712 and EIP-1559).
- `2.json` — an L1->L2 transaction transferring its whole deposit, with a zero gas price.
- `3.json` — the same with a non-zero gas price, so fee and refund effects are visible.
- `4.json` — one that reverts in the target, the baseline a force-failed transaction must match.

Only L2 fixtures get their sender funded by the runner; an L1->L2 transaction is funded by the
bootloader minting its `mintValue`. That mint only works because the runner also presets the
`L2AssetTracker` slots that register the base token (`apply_l1_base_token_minting_slots` in
`src/main.rs`) — a new L1->L2 fixture needs nothing more, but a change to that contract's storage
layout shows up here as a bare `Failed to mint ether`.

Each fixture runs in every test, so a test that force-fails one must expect the others to run
normally around it.

To regenerate fixture transactions:

```shell
cargo run -- --generate-transactions
```

It rewrites every fixture, so run `yarn prettier:fix` afterwards and drop the `0.json`/`1.json`
churn: the L2 fixtures stamp wall-clock time, while the L1->L2 ones are reproducible.

## Expectation hooks in Yul tests

Use these helpers from `../tests/utils/test_utils.yul`:

- `testing_testWillFailWith("...")`
  - for assertion/halt-style failures
- `testing_testTransactionWillFailWith("0x...")`
  - for transaction execution failures in integration flow
  - compares expected full revert returndata hex (normalized to lowercase, optional `0x`)

This separation allows integration tests to assert tx-level revert payloads without conflating them with assertion failures.

## Post-execution expectations

Test bodies run before the transaction loop, so anything about the _outcome_ of a transaction is
registered as an expectation and checked by the runner once the batch is done:

- `testing_expectTxFailureNoReturndata(index)` — expects transaction failure with empty returndata.
- `testing_expectBootloaderLog(key, value)` — the bootloader sent exactly one such L2->L1 log.
- `testing_expectNoBootloaderLogKey(key)` — it sent no log under this key.
- `testing_expectNoBootloaderLog(key, value)` — it sent no such log, for a key another log owns.
- `testing_expectSystemLog(key, value)` — it sent this system log (priority-queue accounting).
- `testing_expectBalance(account, balance)` — exact base token balance at the end of the batch.

Expectations fail closed: a test that registers them and also expects the batch to fail is an
error (they could never be checked), and an `INT_TEST_*` that registers no assertion at all fails
rather than passing vacuously.
