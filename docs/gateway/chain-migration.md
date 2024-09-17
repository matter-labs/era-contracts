# Chain migration

Chain migration uses the Custom Asset Bridging framework:

- CTMs can be deployed on the Gateway. Each CTM has its own assetId.
- The CTM Deployment Tracker deployed on L1 registers assetId in the L1 and L2 AssetRouters, with the Bridgehub as the AssetHandler. It also registers the L1 and L2 CTM contracts to be associated to the assetId in the Bridgehubs.
- Bridging of a chain happens via the Bridgehub, AssetRouters, and CTM.

![CTM assetId registration](./chain-asset-id-registration.png)
_Note these are separate calls_

![Chain migration](./chain-migration.png)
_Note these are a single call with an L1->L2 txs_
