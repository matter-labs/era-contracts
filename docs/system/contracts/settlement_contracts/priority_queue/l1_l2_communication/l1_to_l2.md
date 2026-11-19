# Handling L1 → L2 operations

L1 can initiate two classes of ZKsync OS transactions:

- **Priority operations**, which any user can request through Bridgehub.
- **Protocol-upgrade transactions**, which governance schedules as part of a CTM-approved upgrade.

## Priority operations

A caller uses `requestL2TransactionDirect` or `requestL2TransactionTwoBridges` on `L1Bridgehub`.
Bridgehub resolves the target chain, handles the base-token payment through the asset-routing system,
and forwards the request to the chain's `MailboxFacet`. The mailbox validates the request, derives its
canonical transaction hash, and appends that hash to the chain's priority structure.

The execution environment must process priority operations in order. Its batch output commits to the
number and rolling hash of the processed operations. During batch execution on L1, `ExecutorFacet`
consumes the corresponding queue or priority-tree entries and rejects the batch if their rolling hash
does not match the committed value.

The direct and two-bridges entry points differ in the authenticated L2 sender and asset-routing step.
The current end-to-end deposit flow is specified in {protocol-docs/bridging.md}.

## Upgrade transactions

Only an approved protocol upgrade can schedule a system upgrade transaction. The chain stores the
expected transaction hash and requires the next applicable batch to commit to it. Only one upgrade
transaction may be pending, and it must be processed at the position required by the ZKsync OS batch
format. After the containing batch executes, the pending upgrade state is cleared.

The upgrade lifecycle and its governance boundary are described in
[the upgrade process](../../../chain_management/upgrade_process.md).
