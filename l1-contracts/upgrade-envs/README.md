# upgrade envs

This directory is used to create actual payloads for upgrades.

It contains the $ECOSYSTEM_NAME.toml file with the input data, that is later fed into EcosystemUpgrade.s.sol, which publishes the necessary bytecodes, and creates the output data that ends out in outputs/ dir.

## Generating inputs

Inputs should be generated manually, and are usually a combination of things
that are specific to a given upgrade (for example genesis hashes) and to the
given ecosystem (for example bridgehub address).

We should aim at keeping the inputs as small as possible - as many things should be auto-detected from the network (which makes it less error prone).

## Generating outputs

Outputs usually consist of 4 files:

- ecosystem.toml
- ecosystem.yaml
- run-latest.json
- verification logs

**Ecosystem.toml**
This is the output coming from the running of EcosystemUpgrade.s.sol script with a given's ecosystem input file.

The detailed instructions on how to do it can be found in README of deploy-scripts.

**run-latest.json**

This is the file taken from the broadcast dir, after EcosystemUpgrade script is run. It would contain information about the transacions that were executed etc.

**verification-logs**

This contains commands used to verify the bytecodes on etherscan. Currently has to be created manually by "grep" over the logs from EcosystemUpgrade script.

Note: make sure to add the --chain sepolia when running stage or testnet.

**Ecosystem.yaml**

This is the final file that can be sent for verification. It contains the same fields as Ecosystem.toml, but with addition of list of transaction hashes (as verifier tool needs them to check the correctness of addresses, bytecodes and constructor parameters).

## Important

If you generate the calldata multiple times, then the next runs might no longer deploy the contracts that were not changed.
In such case, you'll have to manually add the transactions that deployed the original contracts to the final yaml file (you can simply add all the transaction hashes from the previous run).
