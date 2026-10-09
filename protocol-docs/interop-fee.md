# Interop fee (L1 operator fee switch)

A fee that chain **operators** pay on L1 for the interop their chains send. It ships **off**: the rate is a settable
parameter that starts at zero, and only the fee manager's owner (protocol governance) can turn it on. It is separate
from, and does not change, the user-side fees `InteropCenter` charges on L2 (see {protocol-docs/interop.md#fee-model}).

## What is charged

A batch is charged `feePerUnit × interopFeeUnits`, where `interopFeeUnits` is the number of **interop calls** the
batch sent: every call of every L2→L2 bundle, so a bundle without calls counts nothing. L2→L1 withdrawals are not
interop and are never counted.

The unit is decided only on L2: `InteropCenter` bumps a monotonic counter, and everything downstream (the bootloader,
the batch output, L1) only carries the difference, so changing the unit is an L2 contract change.

## How the count reaches L1

1. **L2 counter.** `InteropCenter._dispatchBundle` adds `bundle.calls.length` to a counter at the fixed slot
   `INTEROP_FEE_UNITS_SLOT` (`l1-contracts/contracts/common/Config.sol`) in the same call that appends the leg to the
   interop commitment tree. A leg that is not counted is not in the tree, and so can never execute on its
   destination ({protocol-docs/atomicity/README.md}). `interopFeeUnits()` reads the counter; it starts at zero, both
   at genesis and when an upgrade introduces it.
2. **Proven batch output.** The ZKsync OS bootloader reads that slot of `InteropCenter` (`0x1000d`) at the start of
   the batch's first block and at the end of its last block, where it also snapshots the interop commitment tree root
   ({protocol-docs/atomicity/imt.md}), and commits `end − begin` (saturating) as `BatchOutput.interop_fee_units`, the
   last word of the batch output hash. The slot is therefore **consensus-critical**: it must not move without a
   coordinated protocol change.
3. **L1 commit.** `CommitBatchInfoZKsyncOS.interopFeeUnits` is hashed last into the batch output hash
   (`CommitterFacet._getBatchOutputHash`, commit encoding version 6), which goes into the proof public input, and the
   count is recorded for the batch number. A batch committed with a count other than the one its state transition
   produced can't pass verification of a real proof, so it never executes.
4. **L1 execution.** Executing the proven batch charges the recorded count.

The batch output layout is pinned by golden vectors shared with ZKsync OS:
`BATCH_OUTPUT_HASH_GOLDEN_INTEROP_FEE_UNITS_*` in `l1-contracts/test/foundry/TestConstants.sol` and
`batch_output_hash_commits_to_interop_fee_units_last` in ZKsync OS `post_tx_op/public_input.rs`.

## Charging and enforcement

`ExecutorFacet` calls `InteropFeeManager.chargeInteropFee(chainId, batchNumber, units)` for every batch it executes,
when:

- `interopFeeUnits != 0`: batches without interop never touch the manager;
- the batch settles on L1, where the manager lives;
- priority mode is off: the escape hatch never depends on the fee.

The manager debits the chain's **prepaid balance** (`deposit(chainId)`, payable by anyone, withdrawable only by the
chain admin) at the `feePerUnit` in force when the batch executes, so a rate change also applies to batches already
committed. If the balance does not cover the fee, the execution reverts: until the chain is topped up, its batches and
the withdrawals in them can't execute, while committing and proving continue. Its priority transactions aren't processed
either, so once the oldest has waited `PRIORITY_EXPIRATION`, anyone can activate priority mode on a chain that permits
it (`AdminFacet.activatePriorityMode`), which reverts its unexecuted batches.

Only proven counts of executed batches are charged. A reverted batch is never charged, whoever reverts it (the
operator, the CTM, or priority-mode activation): every commit records its batch's count, overwriting the count of a
reverted batch with the same number.

## The switch

`DeployCTM` deploys an `InteropFeeManager` proxy with the CTM, as does the CTM upgrade that introduces it; later
upgrades keep the one the current `ExecutorFacet` charges, which holds the chains' prepaid balances. It is passed to
the `ExecutorFacet` as an immutable and can be read as `getInteropFeeManager()` on the diamond of any chain from v35
on. Its owner is protocol governance from initialization, and controls:

- `feePerUnit`: wei per interop fee unit; `0`, the initial value, turns the switch off;
- `feeRecipient`: where the permissionless `sweep()` sends the accrued fees; initially governance.

Users can choose the fixed per-call ZK fee, which the operator can't reprice, over the operator-set one
({protocol-docs/interop.md#fee-model}), so a `feePerUnit` worth more than `ZK_INTEROP_FEE` lets users make an operator
pay more than it collects.

Fees are paid in ETH. Charging only moves value between the manager's internal ledgers, so the prepaid balances plus
the accrued fees are always backed by the contract's ETH.

## Activation

Commit encoding version 6 appends `interopFeeUnits`; the new decoder rejects earlier commit versions. The server,
external nodes and the ZKsync OS version committing `interop_fee_units` (with its verification key) must switch at
protocol v35. Historical v34 and earlier data must still be decoded using their original formats.

Before upgrading across the v35 boundary, all committed batches must be executed or reverted; `DefaultUpgradeZKsyncOS`
enforces it. Every batch executed after the upgrade was therefore committed with its count recorded.
