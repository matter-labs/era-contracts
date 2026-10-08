# Interop fee (L1 operator fee switch)

A fee that chain **operators** pay on L1 for the interop their chains send. It ships **off**: the rate is a settable
parameter that starts at zero, and only the fee manager's owner (protocol governance) can turn it on. It is separate
from, and does not change, the user-side fees `InteropCenter` charges on L2 (see {protocol-docs/interop.md#fee-model}).

## What is charged

A batch is charged `feePerUnit × interopFeeUnits`, where `interopFeeUnits` is the number of **interop calls** the
batch sent: every call of every L2→L2 bundle. L2→L1 withdrawals are not interop and are never counted.

The unit is decided in one place, on L2, so it can change without touching the proof system: `InteropCenter` bumps a
monotonic counter, and everything downstream (the bootloader, the batch output, L1) only carries the difference.
Counting a different unit (per bundle, per completed flow) is an L2 contract change only.

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
   (`CommitterFacet._getBatchOutputHash`, commit encoding version 6), which goes into the proof public input. A batch
   committed with a count other than the one its state transition produced can't be proven, so it never executes.

The batch output layout is pinned by golden vectors shared with ZKsync OS:
`BATCH_OUTPUT_HASH_GOLDEN_INTEROP_FEE_UNITS_*` in `l1-contracts/test/foundry/TestConstants.sol` and
`batch_output_hash_commits_to_interop_fee_units_last` in ZKsync OS `post_tx_op/public_input.rs`.

## Charging and enforcement

`CommitterFacet` calls `InteropFeeManager.chargeInteropFee(chainId, batchNumber, units)` after validating the batch,
when:

- `interopFeeUnits != 0`: batches without interop never touch the manager;
- the batch settles on L1: the manager is an L1 contract, so batches settled elsewhere are not charged;
- priority mode is off: the escape hatch never depends on the fee.

The manager debits the chain's **prepaid balance** (`deposit(chainId)`, payable by anyone, withdrawable only by the
chain admin). If the balance does not cover the fee, the commit reverts and the chain can't advance until it is
topped up. Batches committed earlier still prove and execute, so in-flight withdrawals keep finalizing.

Charging happens at commit, not at execute, because commit is where the count arrives; binding it into the proof
makes the operator-supplied value safe to charge. The trade-off is that a reverted batch is not refunded, whoever
reverts it (the operator, the CTM, or priority-mode activation): interop re-committed outside priority mode is
charged again.

## The switch

`InteropFeeManager` is one proxy per CTM. `DeployCTM` deploys it, as does the CTM upgrade that introduces it; later
upgrades keep the one the current `CommitterFacet` charges, which holds the chains' prepaid balances. It is passed to
the `CommitterFacet` as an immutable and can be read as `getInteropFeeManager()` on any chain's diamond. Its owner is
protocol governance from initialization, and controls:

- `feePerUnit`: wei per interop fee unit; `0`, the initial value, turns the switch off;
- `feeRecipient`: where the permissionless `sweep()` sends the accrued fees; initially governance. Routing them to the
  $ZK Fee Flow System, which takes approved ERC-20s on ZKsync Era, means pointing it at an L1 contract that forwards
  the ETH there: no protocol upgrade is needed.

Fees are paid in ETH. Charging only moves value between the manager's internal ledgers, so the prepaid balances plus
the accrued fees are always backed by the contract's ETH.

## Activation

The count changes both the commit wire and the ZKsync OS batch output, so it activates with the protocol upgrade
that ships the ZKsync OS version committing `interop_fee_units` (with its verification key) together with the
`CommitterFacet` hashing it. `DefaultUpgradeZKsyncOS` requires every committed batch to be executed first, so no batch
committed in the old layout is left to prove: from the upgrade on, batches are committed with encoding version 6, and
version 5 is rejected.
