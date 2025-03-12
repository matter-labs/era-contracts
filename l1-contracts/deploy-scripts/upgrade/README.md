# Gateway upgrade related scripts

## Setup

```sh
yarn calculate-hashes:check
```

If this fails you have some issues with foundry or your setup. Try cleaning your contracts

## Example of usage

1. Create a file similar to one of those in the `/l1-contracts/upgrade-envs/` for our environment

2. Simulate the deployment

   ```sh
   UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.27.0-evm/stage.toml UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v27-ecosystem.toml forge script --sig "run()" EcosystemUpgrade --ffi --rpc-url $SEPOLIA --gas-limit 20000000000
   ```

3. Run the following to prepare the ecosystem

   ```sh
   UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/v0.27.0-evm/stage.toml UPGRADE_ECOSYSTEM_OUTPUT=/script-out/v27-ecosystem.toml forge script --sig "run()" EcosystemUpgrade --ffi --rpc-url $SEPOLIA --gas-limit 20000000000 --broadcast --slow
   ```

4. Verify contracts based on logs

5. Generate the yaml file for the upgrade

```sh
UPGRADE_ECOSYSTEM_OUTPUT=script-out/v27-ecosystem.toml UPGRADE_ECOSYSTEM_OUTPUT_TRANSACTIONS=broadcast/EcosystemUpgrade.s.sol/<CHAIN_ID>/run-latest.json yarn upgrade-yaml-output-generator
```

e.g.:

```sh
UPGRADE_ECOSYSTEM_OUTPUT=script-out/v27-ecosystem.toml UPGRADE_ECOSYSTEM_OUTPUT_TRANSACTIONS=broadcast/EcosystemUpgrade.s.sol/11155111/run-latest.json yarn upgrade-yaml-output-generator
```

## Finalization of the upgrade

This part will not be verified by governance as it can be done by anyone. To save up funds, we will use `MulticallWithGas` contract.

### Deploying the multicall with gas contract

Firstly, you should deploy the `MulticallWithGas` contract.

After that you should use the zkstack_cli tool to get the calldata for the `FinalizeUpgrade`'s `finalizeInit` function:

```sh
forge script --sig <data-generated-by-zkstack> FinalizeUpgrade.s.sol:FinalizeUpgrade --ffi --rpc-url <rpc-url> --gas-limit 20000000000 --broadcast --slow
```
