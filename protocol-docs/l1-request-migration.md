# L1→L2 request migration to the `L1InteropCenter`

The L1→L2 request surface on the `L1Bridgehub` is deprecated: it is replaced by the `L1InteropCenter`,
which becomes the single user-facing entry point for L1→L2 priority transactions and exposes both
former Bridgehub request modes through ERC-7786 `sendMessage`. The Bridgehub stays the chain /
base-token registry and the source of truth for the active interop-center address (`interopCenter()`),
which downstream contracts read to authorize calls.

This page exists so that the symbols listed below can be marked `@custom:deprecated` in code with a
single pointer here instead of repeating the migration in every file. It describes the _target_ state;
the deprecated symbols are still the live code path until the migration lands.

## Request modes

| Deprecated call                              | Replacement                                                        |
| -------------------------------------------- | ------------------------------------------------------------------ |
| `L1Bridgehub.requestL2TransactionDirect`     | `L1InteropCenter.sendMessage` without an `indirectCall` attribute  |
| `L1Bridgehub.requestL2TransactionTwoBridges` | `L1InteropCenter.sendMessage` with the `indirectCall` attribute    |
| `L1Bridgehub.l2TransactionBaseCost`          | stays, but fee estimation is also exposed by the `L1InteropCenter` |

The per-request fields that used to live in the request structs become ERC-7786 attributes:
`mintValue`, `l2GasLimit`, `l2GasPerPubdataByteLimit` and `refundRecipient` are carried by the
required L1-only `l1ToL2TransactionParams` attribute, `factoryDeps` by the optional (direct-call only)
`factoryDeps` attribute, and the destination-side call value by `interopCallValue`. The recipient is an
ERC-7930 address instead of a `chainId` plus `l2Contract` pair, and `sendMessage` returns the canonical
priority-transaction hash as its `sendId`.

## Renamed symbols

The "two bridges" vocabulary is replaced by "indirect call" / "cross-chain sender":

| Deprecated name                                       | New name                         |
| ----------------------------------------------------- | -------------------------------- |
| `IL1CrossChainSender.bridgehubDeposit`                | `initiateIndirectCall`           |
| `IL1CrossChainSender.bridgehubConfirmL2Transaction`   | `confirmL2Transaction`           |
| `IL1Nullifier.bridgehubConfirmL2TransactionForwarded` | `confirmL2TransactionForwarded`  |
| `L2TransactionRequestTwoBridgesOuter`                 | `L2TransactionRequestIndirect`   |
| `L2TransactionRequestTwoBridgesInner`                 | `IndirectCallRequest`            |
| `TWO_BRIDGES_MAGIC_VALUE`                             | `INDIRECT_CALL_MAGIC_VALUE`      |
| `BRIDGEHUB_MIN_SECOND_BRIDGE_ADDRESS`                 | `MIN_CROSS_CHAIN_SENDER_ADDRESS` |
| `SecondBridgeAddressTooLow`                           | `CrossChainSenderAddressTooLow`  |
| `OnlyBridgehub`                                       | `OnlyInteropCenter`              |

`L2TransactionRequestDirect` disappears entirely: the direct flow is described by the `sendMessage`
arguments and its attributes.

## Authorization

Contracts that today accept calls from the Bridgehub because it forwarded the user's request accept
calls from the interop center instead, resolved dynamically as `bridgehub.interopCenter()` so that a
rotation of the interop-center address needs no downstream redeployment:

- `L1AssetRouter.onlyBridgehub` → `onlyInteropCenter`, `onlyBridgehubOrEra` → `onlyInteropCenterOrEra`
- `CTMDeploymentTracker.onlyBridgehub` and `ChainRegistrationSender.onlyBridgehub` → `onlyInteropCenter`
- `ZKChainBase.onlyBridgehub` → `onlyL1InteropCenter`, gating `MailboxFacet.bridgehubRequestL2Transaction`
  (the Bridgehub itself stops being an authorized request caller)

`PermanentRestriction` recognizes a chain migration from `L1InteropCenter.sendMessage` calldata: the
`indirectCall` attribute must be present and the ERC-7930 recipient must be the asset router, so a
direct message carrying a migration-shaped payload is not misclassified.

## Callers inside this repository

Every in-repo caller of a deprecated symbol migrates together with it. The one that is not a pure
rename is `L1AssetRouter.depositLegacyErc20Bridge`, which builds an `L2TransactionRequestDirect` and
calls `requestL2TransactionDirect`; it has to build a `sendMessage` call instead.

The deploy-script helpers follow the same vocabulary change: `Utils.{prepare,prepareGovernance,prepareAdmin,runAdmin,runGovernance}L1L2*TwoBridges*`
become their `*Indirect*` counterparts and encode `sendMessage` calls through the shared
ERC-7930/ERC-7786 request encoders instead of Bridgehub request structs.
