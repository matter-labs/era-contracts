# Gateway upgrade related scripts

## Example of usage

1. Create a file similar to one of those in the `/l1-contracts/upgrade-envs/` for our environment.
2. Run the following to prepare the ecosystem:

```sh
GATEWAY_UPGRADE_ECOSYSTEM_INPUT=/upgrade-envs/<input-file> forge script --sig 0xc0406226 EcosystemUpgrade --ffi --rpc-url <rpc-url> --gas-limit 20000000000 --broadcast --slow
```
