# Gas snapshots

This directory contains gas snapshots emitted by the `snapshotGas*` cheatcodes.
Currently, this is used to measure `Executor.sol` operations gas usage: `precommit`, `commit`, `prove`, `execute`.

It is intended that the `snapshots` directory created when using the `snapshotGas*` cheatcodes is checked into version control.
This allows us to track changes in gas usage over time and compare gas usage during code reviews.
There is a CI workflow that will fail if the snapshots are not up to date.
