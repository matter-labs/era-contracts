# Upgrade Scripts

## Preparing the scripts for a new upgrade

You can use the latest `EcosystemUpgrade_v**` script as a starting point. As a rule of thumb, all contracts that were changed in the release branch should be upgraded. In case the compiler version or compilation configuration has changed, all contracts have to be upgraded, as the bytecodehashes will change for these contract. In general, deployed contracts should reflect the latest changes to contracts in the repository.

## Patch Upgrades

Patch upgrades tend to introduce minor fixes and so they only modify some contracts. More personal judgement should be used when defining a new patch upgrade scripts. You should have the following pointers in mind:

- You may not need to redefine all four facet cuts, you can override `getUpgradeAddedFacetCuts` to specify only the ones that are needed for the upgrade. The old facets should equally be deleted via `getFacetCutsForDeletion`. Note that when creating a new chain all four facet cuts are needed, as done by `getChainCreationFacetCuts`.
- You may need to override both `deployNewEcosystemContractsL1` and `deployNewEcosystemContractsGW` to only deploy the relevant contracts.
- The addresses for contracts that are not deployed but needed (facets, verifier...) should be read from the input file via `initializeConfig`, and they should equal the latest values.
- Some of the `prepareStage1GovernanceCalls` and `prepareGatewaySpecificStage1GovernanceCalls` may be overridden and left empty if they are not part of the upgrade.

You can check out [EcosystemUpgrade_v29_2.s.sol](./EcosystemUpgrade_v29_2.s.sol) as an example.

## Setup

```sh
yarn calculate-hashes:check
```

If this fails you have some issues with foundry or your setup. Try cleaning your contracts

## Example of usage

1. Create a file similar to one of those in the `/l1-contracts/upgrade-envs/` for our environment

2. Simulate the deployment (Runs EcosystemUpgrade, simulates transactions, outputs the upgrade data, i.e. required addresses, config addresses, protocol version and the Diamond Cuts)

   ```sh
   UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.28.0-precompiles/stage.toml UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v28-ecosystem.toml forge script --sig "run()" EcosystemUpgrade --ffi --rpc-url $SEPOLIA --gas-limit 20000000000 --private-key $PRIVATE_KEY
   ```

3. Run the following to prepare the ecosystem (Similar to the above, broadcasts all the txs, and saves them in run-latest.json). This step only has to be ran once. The private key has to be provided for this step.

   ```sh
   UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.28.0-precompiles/stage.toml UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v28-ecosystem.toml forge script --sig "run()" EcosystemUpgrade --ffi --rpc-url $SEPOLIA --gas-limit 20000000000 --broadcast --slow --private-key $PRIVATE_KEY
   ```

4. Verify contracts based on logs

5. Generate the yaml file for the upgrade (generating calldata)

```sh
UPGRADE_ECOSYSTEM_OUTPUT=script-out/v27-ecosystem.toml UPGRADE_ECOSYSTEM_OUTPUT_TRANSACTIONS=broadcast/EcosystemUpgrade.s.sol/<CHAIN_ID>/run-latest.json YAML_OUTPUT_FILE=script-out/yaml-output.yaml yarn upgrade-yaml-output-generator
```

e.g.:

```sh
UPGRADE_ECOSYSTEM_OUTPUT=script-out/v27-ecosystem.toml UPGRADE_ECOSYSTEM_OUTPUT_TRANSACTIONS=broadcast/EcosystemUpgrade.s.sol/11155111/run-latest.json YAML_OUTPUT_FILE=script-out/yaml-output.yaml yarn upgrade-yaml-output-generator
```

## Finalization of the upgrade

This part will not be verified by governance as it can be done by anyone. To save up funds, we will use `MulticallWithGas` contract.

### Deploying the multicall with gas contract (for v26 only)

Firstly, you should deploy the `MulticallWithGas` contract.

After that you should use the zkstack_cli tool to get the calldata for the `FinalizeUpgrade`'s `finalizeInit` function:

```sh
forge script --sig <data-generated-by-zkstack> FinalizeUpgrade.s.sol:FinalizeUpgrade --ffi --rpc-url <rpc-url> --gas-limit 20000000000 --broadcast --slow
```

## Local testing

```sh
 anvil --fork-url $SEPOLIA
```

(same as testing without broadcast)

```sh
UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.27.0-evm/stage.toml UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v27-ecosystem.toml forge script --sig "run()" EcosystemUpgrade --ffi --rpc-url localhost:8545 --gas-limit 20000000000 --broadcast --slow --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

Generate yaml file from toml:

```sh
UPGRADE_ECOSYSTEM_OUTPUT=script-out/v27-ecosystem.toml UPGRADE_ECOSYSTEM_OUTPUT_TRANSACTIONS=broadcast/EcosystemUpgrade.s.sol/11155111/run-latest.json YAML_OUTPUT_FILE=script-out/v27-stage-output.yaml yarn upgrade-yaml-output-generator
```

Now the protocol upgrade verification tool can be run against anvil and the output, e.g. (in the repo of the verifier) :

```sh
cargo run -- --ecosystem-yaml $ZKSYNC_HOME/contracts/l1-contracts/script-out/v27-stage-output.yaml --l1-rpc http://localhost:8545  --era-chain-id 270 --bridgehub-address 0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE
```

## Finalization of the upgrade

This part will not be verified by governance as it can be done by anyone. To save up funds, we will use `MulticallWithGas` contract.

### Deploying the multicall with gas contract (for v26 only)

Firstly, you should deploy the `MulticallWithGas` contract.

After that you should use the zkstack_cli tool to get the calldata for the `FinalizeUpgrade`'s `finalizeInit` function:

```sh
forge script --sig <data-generated-by-zkstack> FinalizeUpgrade.s.sol:FinalizeUpgrade --ffi --rpc-url <rpc-url> --gas-limit 20000000000 --broadcast --slow
```

## Exact steps for testnet

- Create output/testnet directory

```shell
# (XXXX is your API key from alchemy)
export SEPOLIA="https://eth-sepolia.g.alchemy.com/v2/XXXXXX

UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.27.0-evm/testnet.toml  UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v27-ecosystem-testnet.toml forge script --sig "run()" EcosystemUpgrade --ffi --rpc-url $SEPOLIA --gas-limit 20000000000

```

- Get all the 'forge verify-call' entries from the logs, and put them in verification-logs file in the output dir
- for stage & testnet - you have to also add the '--chain sepolia` to the end of each line

Now it is time to actually send some data to sepolia - you'll need your own $WALLET_ADDRESS and $PRIVATE_TESTNET_KEY for this wallet

```shell
UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.27.0-evm/testnet.toml UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v27-ecosystem-testnet.toml forge script --sig "run()" EcosystemUpgrade --ffi --rpc-url $SEPOLIA --gas-limit 20000000000 --broadcast --slow --sender $WALLET_ADDRESS --private-keys $PRIVATE_TESTNET_KEY
```

```shell
cp broadcast/EcosystemUpgrade.s.sol/11155111/run-latest.json upgrade-envs/v0.27.0-evm/output/testnet
cp script-out/v27-ecosystem-testnet.toml upgrade-envs/v0.27.0-evm/output/testnet/v27-ecosystem.toml
```

Now generate the "yaml" file with all the data

```shell
YAML_OUTPUT_FILE=upgrade-envs/v0.27.0-evm/output/testnet/v27-ecosystem.yaml UPGRADE_ECOSYSTEM_OUTPUT=script-out/v27-ecosystem-testnet.toml UPGRADE_ECOSYSTEM_OUTPUT_TRANSACTIONS=broadcast/EcosystemUpgrade.s.sol/11155111/run-latest.json yarn upgrade-yaml-output-generator
```

**IMPORTANT** If you have to re-run generation it in the future, please manually include previous tx hashes from the yaml file into the new one. (this is due to the fact that bytecodes that were already published would not be re-sent - and the verification tool would not be able to confirm their correctness without the original tx that created it).

Afterwards, please verify the contracts:

```shell
source upgrade-envs/v0.27.0-evm/output/testnet/verification-logs
```

Now, go to [protocol-upgrade-verification-tool](https://github.com/matter-labs/protocol-upgrade-verification-tool) - and proceed to verify the yaml file.
