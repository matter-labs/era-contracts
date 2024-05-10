## ITransactionFilterer

### isTransactionAllowed

```solidity
function isTransactionAllowed(address sender, address contractL2, uint256 mintValue, uint256 l2Value, bytes l2Calldata, address refundRecipient) external view returns (bool)
```

Check if the transaction is allowed

| Name | Type | Description |
| ---- | ---- | ----------- |
| sender | address | The sender of the transaction |
| contractL2 | address | The L2 receiver address |
| mintValue | uint256 | The value of the L1 transaction |
| l2Value | uint256 | The msg.value of the L2 transaction |
| l2Calldata | bytes | The calldata of the L2 transaction |
| refundRecipient | address | The address to refund the excess value |

| Name | Type | Description |
| ---- | ---- | ----------- |
| [0] | bool | Whether the transaction is allowed |

