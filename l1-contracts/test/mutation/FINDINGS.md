# Atomic-interop mutation testing — findings

Results of running the suite in `test/mutation/` against the atomicity feature. The machine-generated
data (per-file/per-operator tables, full survivor list) is in `out/report.md`; this document tracks
the campaign history and triages the residual survivors.

## Campaign history

| pass                                                     | score     | killed | survived |
| -------------------------------------------------------- | --------- | ------ | -------- |
| 1 — initial run                                          | 70.8%     | 306    | 126      |
| 2 — kill signal extended with `L2InteropCenterL1Test`    | 74.8%     | 323    | 109      |
| 3 — after the gap-closure test PR (37 new foundry tests) | **94.0%** | 406    | 26       |

5 uncompilable mutants are excluded from every score (the compiler, not the tests, rejects them).

## Gaps found by pass 1/2 — all closed by the test PR

1. **The atomic finalize/execute path had NO foundry coverage** (the headline finding —
   `L2InteropHandler.executeAtomicBundle` scored 0%, all 39 mutants survived; the main body of
   `AtomicFlowManager.requireFlowFinalized` was equally untested, its only test stopping at the early
   settlement-layer revert). Closed by `AtomicFlowManagerFinalize.t.sol` (9 unit tests over the gate:
   per-leg verification incl. first/last-leg atomicity, proof-count/source-chain binding, flow-id
   check, executing-bundle membership, ACL) and `L2AtomicInteropExecuteTestAbstract.t.sol` (8
   integration tests through the real entry point: happy execute with mint/status/event, replay
   guard, missing-leg atomicity, proof-count wiring, foreign-flow rejection, wrong-destination
   context, chain-bound executor gate incl. foreign-chain binding, no stray call-status writes).
2. **`AtomicInteropProof._verifyLastBatchInRoot` was only tested with a zero batch-leaf mask** — the
   per-level "left child ⇒ empty right subtree" logic authenticating the halted-chain timeout branch
   was unverified for real (non-leftmost) tree positions. Closed by the right-child-last-leaf happy
   case, the deeper-level non-last revert, and the wrong-cascade-level revert in
   `AtomicInteropProof.t.sol` (built on the new `_settlementProofWithMask` builder).
3. **Timeout begin-branch boundary at `l1BatchTimestamp == deadline`** untested. Closed by
   `test_RevertWhen_timeout_beginBranchWithBatchAtDeadline`.
4. **`InteropCenter._validateAtomicBundle` (native-`value` leg rejection) entirely untested.** Closed
   by `test_atomicSend_RevertWhen_CallCarriesValue` (real send path). The `_parseAtomicSend`
   attribute scan was also position-dependent-untested — closed by
   `test_atomicSend_AtomicAttributeFirstInArray`.
5. **`L2InteropCommitmentTree` guards and events unasserted** (upgrader/appender ACLs, `RootUpdated`
   payloads). Closed by `L2InteropCommitmentTreeAccess.t.sol`.
6. **Refund-path guards unasserted at the manager level** (absence-proof source-chain binding — the
   double-mint guard —, flow-id check, proof-verification-before-state-change, only-Committed-legs
   marking, claim state machine incl. double-claim). Closed by `AtomicFlowManagerRefund.t.sol` and
   the claim state-machine additions to `L2AtomicInteropSendRefundTestAbstract.t.sol`.
7. **`AtomicFlowManager.append` residuals**: duplicate (equal-adjacent) leg hashes and the
   registration gate's first-slot co-leg. Closed by the two new `AtomicFlowManagerAppend.t.sol`
   tests.

## Residual survivors (26) — triaged, no action needed

**Equivalent mutants (10):**

- `ChainBatchRootTree` L32/L36 (3): `LOGS_ROOT_LEAF_INDEX` / `MULTICHAIN_ROOT_LEAF_INDEX` are
  documented in-source as unused, kept for layout completeness. Mutating them changes no behaviour.
- `IndexedMerkleTree` L51 (2): `setup` writes the `{0,0,0}` head leaf into already-zero storage —
  deleting or re-indexing the write is a no-op (the tree hash comes from `pushNewLeaf`, tested).
- `IndexedMerkleTree` L82/L86 (2): the mutated `==` boundaries are unreachable — a duplicate value is
  rejected earlier by `valueToIndex`. Defensive redundancy.
- `L2InteropHandler` (3): `_ensureNotPaused()` is a no-op virtual on L2 (never overridden);
  `msg.sender == address(this)` (the `receiveMessage` self-execution branch) is unreachable for
  atomic bundles — nothing in production self-calls `executeAtomicBundle`; the
  `new CallStatus[](0)` argument is ignored when `_executeAllCalls = true`.

**Generic send-path code, covered by dedicated non-atomic suites (16):** the mutation scope includes
all of `InteropCenter._sendBundle` (the atomic send funnels through it), so mutants in its
bundle-salt guard, destination base-token asset-id derivation, ZK fixed-fee accounting, value
collection, and `MessageSent` emission survive the _atomicity_ kill signal. These behaviours are not
atomic-specific and have their own suites (`L2InteropBundleSaltTestAbstract`,
`L2InteropFeesTestAbstract`, `L2InteropIndirectCallValueRegressionTestAbstract`, handler/eventing
suites) that are deliberately not part of the per-mutant signal. Extending `KILL_SIGNAL_TESTS` with
those suites would convert most of them to kills at the cost of a slower campaign.

## Reproduce

```bash
cd l1-contracts
node test/mutation/mutate.js generate   # 437 mutants -> out/mutants.json
node test/mutation/mutate.js run        # resumable; writes out/results.json
node test/mutation/mutate.js report     # out/report.md
```

The run uses the foundry-zksync build in `<repo>/foundry-zksync` and builds mutants with the
optimizer disabled (behaviour-preserving for these logic tests; keeps common-library rebuilds to
~45s instead of minutes). See `README.md` for details and env overrides.
