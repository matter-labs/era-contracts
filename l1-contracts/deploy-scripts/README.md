# Deployment Scripts

## DeployAndVerifyDiamondProxy

This script can be used to deploy and verify the `DiamondProxy` contract.

To use it, run:

```bash
forge script DeployAndVerifyDiamondProxy.s.sol \
  --broadcast \
  --private-key [YOUR_PRIVATE_KEY] \
  --rpc-url [YOUR_RPC_URL] \
  --verify \
  --etherscan-api-key [YOUR_ETHERSCAN_API_KEY]
```

That command will deploy DiamondProxy to the network you specify via --rpc-url and then automatically verify the source on Etherscan.