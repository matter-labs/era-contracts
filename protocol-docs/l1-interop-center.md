# L1 Interop Center

The `L1InteropCenter` exposes L1→L2 requests through the same ERC-7786 `sendMessage` shape the L2
`InteropCenter` uses, without moving any request logic out of the Bridgehub. It holds no state, has no
owner, and is permissionless: it maps a message onto one of the two Bridgehub request modes and calls
the Bridgehub, which performs the request exactly as it does for a direct caller.

Both Bridgehub entry points stay in place and unchanged. The interop center is an additional entry
point in front of them, so integrations can move to the interop-native shape at their own pace and
keep working once the request flow itself moves into the interop center.

## Message shape

| Message                       | Relayed to                                      |
| ----------------------------- | ----------------------------------------------- |
| no `indirectCall` attribute   | `L1Bridgehub.requestL2TransactionDirectFor`     |
| with `indirectCall` attribute | `L1Bridgehub.requestL2TransactionTwoBridgesFor` |

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
forwarded to the Bridgehub, which enforces the base-token value rules.

## Trusted forwarding

The Bridgehub would otherwise record its own caller — the interop center — as the account behind the
request: the L1→L2 transaction would arrive from the interop center's alias, the base token would be taken
from the interop center, and a cross-chain sender would attribute the deposit to it, leaving the depositor
unable to recover a failed deposit.

To avoid that, the Bridgehub keeps the address of one interop center (`interopCenter`, set by the owner or
the upgrader) and exposes `requestL2TransactionDirectFor` / `requestL2TransactionTwoBridgesFor`, which take
the account the request is made for and are callable only by it. The interop center passes its own
`msg.sender` and nothing else, so a relayed request is indistinguishable from one the sender made directly:
the base token comes from their allowance, they are the sender of the L1→L2 transaction, the fee refund
defaults to them, and an indirect call reaches the cross-chain sender with them as the depositor.

The interop center is therefore fully trusted with the identity it forwards: it could request a transaction
as any address and spend that address' base-token and bridge allowances. That is why the address is a single
governance-set slot rather than an open registration, and why the interop center itself holds no state,
has no owner and no upgrade path — its only behavior is to forward its own caller. The existing entry
points are unchanged and remain the way to request a transaction without involving the interop center at
all; pausing the Bridgehub pauses both.

## Indirect calls

Indirect calls behave exactly as they do when the Bridgehub is called directly, including asset-router
deposits: the depositor recorded on L1 is the account that called `sendMessage`. Cross-chain senders that
authorize their caller (for example the CTM deployment tracker, which requires its owner) keep working when
that owner is the one sending the message.
