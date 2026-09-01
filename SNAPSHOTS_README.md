# Gas snapshots

This directory contains gas snapshots emitted by the `snapshotGas*` cheatcodes.
Currently, this is used to measure `Executor.sol` operations gas usage: `precommit`, `commit`, `prove`, `execute`.

It is intended that the `snapshots` directory created when using the `snapshotGas*` cheatcodes is checked into version control.
This allows us to track changes in gas usage over time and compare gas usage during code reviews.
A CI check that fails when the snapshots are out of date exists but is currently disabled pending a foundry upgrade.
