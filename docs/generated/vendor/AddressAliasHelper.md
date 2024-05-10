## AddressAliasHelper

### offset

```solidity
uint160 offset
```

### applyL1ToL2Alias

```solidity
function applyL1ToL2Alias(address l1Address) internal pure returns (address l2Address)
```

Utility function converts the address that submitted a tx
to the inbox on L1 to the msg.sender viewed on L2

| Name | Type | Description |
| ---- | ---- | ----------- |
| l1Address | address | the address in the L1 that triggered the tx to L2 |

| Name | Type | Description |
| ---- | ---- | ----------- |
| l2Address | address | L2 address as viewed in msg.sender |

### undoL1ToL2Alias

```solidity
function undoL1ToL2Alias(address l2Address) internal pure returns (address l1Address)
```

Utility function that converts the msg.sender viewed on L2 to the
address that submitted a tx to the inbox on L1

| Name | Type | Description |
| ---- | ---- | ----------- |
| l2Address | address | L2 address as viewed in msg.sender |

| Name | Type | Description |
| ---- | ---- | ----------- |
| l1Address | address | the address in the L1 that triggered the tx to L2 |

### actualRefundRecipient

```solidity
function actualRefundRecipient(address _refundRecipient, address _prevMsgSender) internal view returns (address _recipient)
```

Utility function used to calculate the correct refund recipient

| Name | Type | Description |
| ---- | ---- | ----------- |
| _refundRecipient | address | the address that should receive the refund |
| _prevMsgSender | address | the address that triggered the tx to L2 |

| Name | Type | Description |
| ---- | ---- | ----------- |
| _recipient | address | the corrected address that should receive the refund |

