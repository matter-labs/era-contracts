## UpgradeHyperchains

This upgrade will be used to migrate Era to be part of the hyperchain ecosystem contracts.

### upgrade

```solidity
function upgrade(struct ProposedUpgrade _proposedUpgrade) public returns (bytes32)
```

The main function that will be called by the upgrade proxy.

| Name | Type | Description |
| ---- | ---- | ----------- |
| _proposedUpgrade | struct ProposedUpgrade | The upgrade to be executed. |

