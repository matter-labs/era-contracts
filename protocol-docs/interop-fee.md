# Interop fee (L1 operator fee switch)

A network-level fee that chain **operators** pay on L1 for the interop their chains send. It ships **off**: the
rate is a settable parameter that starts at zero, and only the fee manager's owner (protocol governance) can turn it
on. It is separate from, and does not change, the user-side fees `InteropCenter` charges on L2 (see
{protocol-docs/interop.md#fee-model}).

## What is charged

A batch is charged `feePerUnit × interopFeeUnits`, where `interopFeeUnits` is the number of **interop calls** the
batch sent: every call of every L2→L2 bundle. L2→L1 withdrawals are not interop and are never counted.

The unit is decided in one place, on L2, so it can change without touching the proof system: `InteropCenter` bumps a
monotonic counter, and everything downstream (the bootloader, the batch output, L1) only carries the difference.
Counting a different unit (per bundle, per completed flow) is an L2 contract change only.

## How the count reaches L1

1. **L2 counter.** `InteropCenter._dispatchBundle` adds `bundle.calls.length` to a counter at the fixed slot
   `INTEROP_FEE_UNITS_SLOT` (`common/Config.sol`) in the same call that appends the leg to the interop commitment
   tree. A leg that is not counted is not in the tree, and so can never execute on its destination
   ({protocol-docs/atomicity/README.md}). `interopFeeUnits()` reads the counter.
2. **Proven batch output.** The ZKsync OS bootloader reads that slot of `InteropCenter` (`0x1000d`) at the start of
   the batch's first block and at the end of its last block — the same points where it snapshots the interop
   commitment tree root — and puts `end − begin` (saturating) into `BatchOutput.interop_fee_units`, the last field
   of the batch output hash. The slot is therefore **consensus-critical**: it must not move without a coordinated
   protocol change.
3. **L1 commit.** `CommitBatchInfoZKsyncOS.interopFeeUnits` is hashed last into `batchOutputHash`
   (`Committer._getBatchOutputHash`, commit encoding version 6), which goes into the proof public input. A wrong count
   makes the batch unprovable, so every batch that is ever executed was charged its proven count.

The batch-output layout is pinned on both sides by shared golden vectors
(`BATCH_OUTPUT_HASH_GOLDEN_INTEROP_FEE_UNITS_*` in `test/foundry/TestConstants.sol`).

## Charging and enforcement

`CommitterFacet` calls `InteropFeeManager.chargeInteropFee(chainId, batchNumber, units)` while committing, when:

- `interopFeeUnits != 0` — batches without interop never touch the manager;
- the batch settles on L1 — the manager is an L1 contract, so batches settled elsewhere are not charged;
- priority mode is off — the escape hatch never depends on the fee.

The manager debits the chain's **prepaid balance** (`deposit(chainId)`, payable by anyone, withdrawable only by the
chain admin). If the balance does not cover the fee, the commit reverts and the chain can't advance until it is
topped up. Batches committed earlier still prove and execute, so in-flight withdrawals keep finalizing.

Charging happens at commit, not at execute: commit is where the count arrives, and binding it into the proof makes
an unproven count harmless. The trade-off is that `revertBatches` does not refund: interop in a reverted batch is
charged again when it is re-committed. Reverts are rare and operator-initiated.

## The switch

`InteropFeeManager` is one proxy per ecosystem, deployed with the CTM and passed to the `CommitterFacet` as an
immutable. Its owner (protocol governance; the deployer until ownership is accepted) controls:

- `feePerUnit` — wei per interop fee unit; `0` (the initial value) turns the switch off;
- `feeRecipient` — where `sweep()` (permissionless) sends the accrued fees, e.g. the $ZK Fee Flow System once
  governance adopts it.

Fees are paid in ETH. Charging only moves value between the manager's internal ledgers: the contract always holds
exactly the prepaid balances plus the accrued fees.
