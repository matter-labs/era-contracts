# Gateway upgrade related scripts

## Example of usage

1. Create a file similar to one of those in the `/l1-contracts/upgrade-envs/` for our environment.
2. Run the following to prepare the ecosystem:

```sh
GATEWAY_UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/<input-file> forge script --sig "run()" EcosystemUpgrade --ffi --rpc-url <rpc-url> --gas-limit 20000000000 --broadcast --slow
```

## Finalization of the upgrade

This part will not be verified by governance as it can be done by anyone. To save up funds, we will use `MulticallWithGas` contract.

### Deploying the multicall with gas contract

Firstly, you should deploy the `MulticallWithGas` contract.

After that you should use the zkstack_cli tool to get the calldata for the `FinalizeUpgrade`'s `finalizeInit` function:

```sh
forge script --sig <data-generated-by-zkstack> FinalizeUpgrade.s.sol:FinalizeUpgrade --ffi --rpc-url <rpc-url> --gas-limit 20000000000 --broadcast --slow
```
