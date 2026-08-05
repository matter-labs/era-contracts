# L1 Interop Center

The `L1InteropCenter` exposes L1→L2 requests through the same ERC-7786 `sendMessage` shape the L2
`InteropCenter` uses, without moving any request logic out of the Bridgehub. It holds no state, has no
owner, and is permissionless: it maps a message onto one of the two Bridgehub request modes and calls
the Bridgehub, which performs the request exactly as it does for a direct caller.

Both Bridgehub entry points stay in place and unchanged. The interop center is an additional entry
point in front of them, so integrations can move to the interop-native shape at their own pace and
keep working once the request flow itself moves into the interop center.

## Message shape

| Message                       | Relayed to                                   |
| ----------------------------- | -------------------------------------------- |
| no `indirectCall` attribute   | `L1Bridgehub.requestL2TransactionDirect`     |
| with `indirectCall` attribute | `L1Bridgehub.requestL2TransactionTwoBridges` |

The recipient is an ERC-7930 address: its chain reference selects the destination chain, and its address
part is the contract called on the destination chain (direct calls) or the L1 cross-chain sender that
constructs the destination-side call (indirect calls). The fields that the Bridgehub request structs
carry explicitly come from attributes instead:

- `l1ToL2TransactionParams(mintValue, l2GasLimit, l2GasPerPubdataByteLimit, refundRecipient)` — required;
  without it the priority transaction cannot be formed.
- `interopCallValue(value)` — the destination-side call value (`l2Value`).
- `indirectCall(value)` — marks the indirect mode; the value is passed to the cross-chain sender on L1
  (`secondBridgeValue`).
- `factoryDeps(deps)` — direct calls only; for indirect calls the cross-chain sender supplies them.

`sendMessage` returns the canonical priority-transaction hash as its `sendId`, and the whole `msg.value` is
forwarded to the Bridgehub, which enforces the base-token value rules. For a chain whose base token is an
ERC20, the native token vault pulls `mintValue` from the Bridgehub's caller — the interop center — so the
sender approves the interop center for `mintValue` and it forwards that allowance to the vault.

## The message sender on the destination chain

The Bridgehub records its own caller as the sender of the L1→L2 transaction, so a relayed request arrives
on the destination chain from the interop center's alias rather than the alias of the account that called
`sendMessage`. The fee refund is unaffected: the interop center resolves an omitted `refundRecipient` to
its own caller before relaying, instead of letting the Bridgehub default it to the interop center itself.

Callers that need the destination chain to see the original sender must keep using the Bridgehub entry
points directly. Preserving the sender through the interop center requires the request to be issued by the
interop center itself, which in turn requires the Mailbox and the cross-chain senders to authorize it —
that is the migration this contract deliberately avoids.

## Indirect calls

A cross-chain sender is called by the Bridgehub with the Bridgehub's caller as the original caller, so a
relayed indirect call is attributed to the interop center. For the asset router this would mean the
interop center — not the user — is recorded as the depositor and would be the only account able to recover
a failed deposit, so indirect calls whose recipient is the asset router are rejected
(`IndirectCallToAssetRouterMustUseBridgehub`): asset deposits keep using the Bridgehub.

Cross-chain senders that do not depend on the caller's identity (for example the chain-registration sender)
work through the interop center. Senders that authorize the original caller (for example the CTM deployment
tracker, which requires its owner) do not, for the same reason as above.
