# Custom Asset Bridging

## High-level Overview

### Reason for changes

The goal was to be build a modular bridge which separates the logic of L1<>L2 messaging from the holding of the asset. This enables bridging many custom tokens, assets which accrue value over time (like LRTs), WETH, and even custom assets like NFTs.

This upgrade only contains the framework, the logic of the custom bridges can be developed by third parties.

### Major changes

In order to achieve it, we separated the liquidity managing logic from the Shared Bridge to `Asset Handlers`. The basic cases will be handled by `Native Token Vaults`, which are handling all of the standard `ERC20 tokens`, as well as `ETH`.

### New concepts

- AssetDeploymentTracker => contract that manages the deployment of asset handlers across chains. It is the contract that registers these asset handlers in the AssetRouters.
- AssetHandler => contract that manages liquidity (burns/mints, locks/unlocks) for specific token (or a set of them)
- assetId => identifier to track bridged assets across chains linked to specific asset handler.

### Normal flow

Assets Handlers are registered in the Routers based on their assetId. The assetId is used to identify the asset when bridging, it is sent with the cross-chain transaction data and Router routes the data to the appropriate Handler. If the asset handler is not registered in the L2 Router, then the L1->L2 bridging transaction will fail on the L2 (expect for NTV assets, see below).

`assetId = keccak256(chainId, asset deployment tracker = msg.sender, additionalData)`

Asset registration is handled by the AssetDeploymentTracker. It is expected that this contract is deployed on the L1. Registration can be permissionless depending on the Asset (e.g. the AssetHandler can be deployed on the chain at a predefined address, this can message the L1 ADT, which can then register the asset in the Router). Registering the L1 Handler in the L1 Router can be done via a direct function call from the L1 Deployment Tracker. Registration in the L2 Router is done indirectly via the L1 Router.

![Asset Registration](./asset-registration.png)

The Native Token Vault is a special case of the Asset Handler, as we want it to support automatic bridging. This means it should be possible to bridge a L1 token to an L2 without deploying the Token contract beforehand and without registering it in the L2 Router. For NTV assets, L1->L2 transactions where the AssetHandler is not registered will not fail, but the message will be automatically be forwarded to the L2NTV. Here the contract checks that the asset is indeed deployed by the L1NTV, by checking that the assetId contains the correct ADT address (note, for NTV assets the ADT is the NTV and the used address is the L2NTV address). If the assetId is correct, the token contract is deployed.

![Automatic Bridge](./automatic-bridging.png)

