// SPDX-License-Identifier: MIT
"use strict";

/**
 * Configuration for the atomic-interop mutation testing suite.
 *
 * The suite is deliberately scoped to the atomicity feature: the contracts that implement it,
 * the substrate data structure it relies on, and the atomic-only code paths of the two entry-point
 * contracts. Everything is expressed relative to the l1-contracts package.
 *
 * Tiers let the report separate the score of the atomicity logic proper ("core") from its shared
 * substrate ("substrate") and the send/execute entry points ("entrypoint").
 */

const path = require("path");

// test/mutation -> l1-contracts -> repo root
const L1_DIR = path.resolve(__dirname, "..", "..");
const REPO_ROOT = path.resolve(L1_DIR, "..");

/**
 * A target is a contract file (relative to l1-contracts) plus an optional list of function names to
 * restrict mutation to. When `functions` is omitted the whole file is mutated. Restricting by
 * function is used for the large entry-point contracts, where only the atomic-specific code is in
 * scope.
 */
const TARGETS = [
  // --- Atomicity core ---------------------------------------------------------------------------
  {
    file: "contracts/atomic-interop/AtomicFlowManager.sol",
    tier: "core",
  },
  {
    file: "contracts/atomic-interop/libraries/AtomicInteropProof.sol",
    tier: "core",
  },
  {
    file: "contracts/atomic-interop/L2InteropCommitmentTree.sol",
    tier: "core",
  },
  {
    // The batch-root leaf layout (begin=2 / end=3 leaves) that the proofs authenticate against.
    file: "contracts/common/libraries/ChainBatchRootTree.sol",
    tier: "core",
  },

  // --- Substrate --------------------------------------------------------------------------------
  {
    // The Indexed Merkle Tree engine the commitment tree and the proofs both delegate to.
    file: "contracts/common/libraries/IndexedMerkleTree.sol",
    tier: "substrate",
  },

  // --- Entry points (atomic-only functions) -----------------------------------------------------
  {
    file: "contracts/interop/interop-handler/L2InteropHandler.sol",
    tier: "entrypoint",
    functions: ["executeAtomicBundle"],
  },
  {
    file: "contracts/interop/InteropCenter.sol",
    tier: "entrypoint",
    functions: ["_sendBundle", "_dispatchBundle", "_validateAtomicBundle", "_parseAtomicSend"],
  },
];

/**
 * The atomicity-focused kill signal: the foundry test files that cover the targets above. A mutant
 * is KILLED iff at least one of these tests fails against it. Scoping the signal this tightly is the
 * point of the exercise — a survivor here is a genuine gap in the *atomicity* test suite, even if
 * some unrelated test elsewhere in the repo would happen to catch it.
 */
const KILL_SIGNAL_TESTS = [
  // AtomicFlowManager
  "AtomicFlowManagerAppend",
  "AtomicFlowManagerInit",
  "AtomicFlowManagerFinalize",
  "AtomicFlowManagerRefund",
  "AtomicRecoveryForgery",
  // AtomicInteropProof
  "AtomicInteropProof",
  // L2InteropCommitmentTree
  "L2InteropCommitmentTreeStorage",
  "L2InteropCommitmentTreeAccess",
  // Substrate + support contracts
  "IndexedMerkleTree",
  "ChainBatchRootTree",
  "L2InteropRootStorage",
  // End-to-end atomic send/refund + execute/finalize (InteropCenter + L2InteropHandler atomic paths)
  "L2AtomicInteropSendRefundL1Test",
  "L2AtomicInteropExecuteL1Test",
  // InteropCenter send-path suite; includes the atomic-bundle-to-L1 rejection assertion.
  "L2InteropCenterL1Test",
];

const KILL_SIGNAL_MATCH_PATH = `**/{${KILL_SIGNAL_TESTS.join(",")}}.t.sol`;

/**
 * Domain-specific symbol groups whose members are interchangeable at the type level but carry
 * distinct atomicity semantics. The SymbolSwap operator replaces each occurrence of a member with
 * every sibling in its group — directly probing tests for, e.g., the batch begin/end leaf mixup or a
 * wrong leg-state transition.
 */
const SWAP_GROUPS = [
  // Batch-begin vs batch-end IMT root leaf index (the finalize/timeout branch pivot).
  ["IMT_BEGIN_ROOT_LEAF_INDEX", "IMT_END_ROOT_LEAF_INDEX"],
  // Leg state machine (Unset -> Committed -> Revertable -> Reverted).
  ["Unset", "Committed", "Revertable", "Reverted"],
];

module.exports = {
  L1_DIR,
  REPO_ROOT,
  TARGETS,
  KILL_SIGNAL_TESTS,
  KILL_SIGNAL_MATCH_PATH,
  SWAP_GROUPS,
  // Forge invocation. FORGE_BIN / extra PATH entry are overridable via env so CI or a local dev can
  // point at whichever foundry-zksync build they use.
  FORGE_BIN: process.env.MUT_FORGE_BIN || "forge",
  FORGE_PATH_PREPEND: process.env.MUT_FORGE_PATH || path.join(REPO_ROOT, "foundry-zksync"),
  // Build mutants with the optimizer disabled (much faster common-library rebuilds; see forgeEnv).
  FOUNDRY_OPTIMIZER_OFF: process.env.MUT_OPTIMIZER_OFF !== "0",
  BUILD_TIMEOUT_MS: 240000,
  // The kill-signal suite runs in ~2s; a mutant that hangs it (e.g. a loop-bound mutation) is a
  // detected divergence -> KILLED. Cap generously above the real runtime but low enough that such a
  // mutant does not dominate a chunk's wall-clock budget.
  TEST_TIMEOUT_MS: 60000,
  // Output artifacts (relative to this directory).
  MUTANTS_FILE: path.join(__dirname, "out", "mutants.json"),
  RESULTS_FILE: path.join(__dirname, "out", "results.json"),
  REPORT_FILE: path.join(__dirname, "out", "report.md"),
};
