/**
 * Collects execution traces from Anvil chains using debug_traceTransaction.
 *
 * Uses stack-enabled tracing to properly track which contract's code is
 * executing at each depth level. When a CALL/DELEGATECALL/STATICCALL is
 * encountered, the target address is read from the EVM stack, and subsequent
 * PCs at the deeper level are attributed to the correct contract.
 *
 * IMPORTANT: Anvil must be started with --steps-tracing for debug_traceTransaction
 * to return non-empty structLogs.
 */

import { createProvider } from "../core/utils";

/** Per-contract execution data: set of PCs that were executed */
export type ContractPCs = Map<string, Set<number>>;

interface StructLog {
  pc: number;
  op: string;
  depth: number;
  stack?: string[];
}

interface TraceResult {
  structLogs: StructLog[];
  failed: boolean;
  gas: number;
}

/** Opcodes that transfer execution to another contract */
const CALL_OPCODES = new Set(["CALL", "STATICCALL", "DELEGATECALL", "CALLCODE"]);

/**
 * Extracts the target address from the EVM stack for a CALL-family opcode.
 *
 * Stack layouts:
 *   CALL:         [gas, addr, value, ...]
 *   STATICCALL:   [gas, addr, ...]
 *   DELEGATECALL: [gas, addr, ...]
 *   CALLCODE:     [gas, addr, value, ...]
 *
 * Stack is top-first in the trace output (last element = top of stack).
 */
function extractCallTarget(log: StructLog): string | null {
  if (!log.stack || log.stack.length < 2) return null;
  // In Anvil's trace, stack[0] is bottom, stack[last] is top.
  // For CALL: top is gas, second-from-top is addr
  const stackLen = log.stack.length;
  const addrHex = log.stack[stackLen - 2]; // second from top = address
  if (!addrHex) return null;
  // Normalize to 40-char hex address
  return "0x" + addrHex.padStart(40, "0").slice(-40).toLowerCase();
}

/**
 * Collects all executed (address, PC) pairs from a single Anvil chain.
 *
 * For each transaction, maintains a depth stack tracking which contract's
 * code is executing at each level. CALL/DELEGATECALL transitions push
 * the target address onto the stack; returning pops it.
 *
 * For DELEGATECALL: the code at the target address executes in the
 * caller's storage context, but the PCs correspond to the target's
 * deployed bytecode. We attribute PCs to the target (code) address.
 *
 * @param rpcUrl - The Anvil RPC URL
 * @param label - Human-readable chain label for logging
 * @returns Map of lowercase address -> set of executed PCs
 */
/** What a chain's trace collection actually managed to do, so callers can tell failure from silence. */
export interface ChainTraceResult {
  contractPCs: ContractPCs;
  /** Transactions found on the chain. */
  transactions: number;
  /** Transactions whose debug_traceTransaction call failed. */
  traceFailures: number;
}

/**
 * Fails when a run executed transactions but produced nothing usable.
 *
 * Per-transaction trace errors are only warnings — one odd transaction should not sink a run — but
 * that means a systemic regression (steps-tracing not enabled, an Anvil API change, a wrong RPC)
 * looks exactly like "no coverage": an LCOV is still written, the mergers only check that the file
 * exists, and coverage-report goes green with a zero-hit Anvil contribution.
 */
export function assertTracesUsable(stats: {
  transactions: number;
  traceFailures: number;
  tracedContracts: number;
  hitSourceFiles: number;
}): void {
  if (stats.transactions === 0) {
    // Not a failure at this level: some specs only read. 04-gateway-setup and
    // 01-deployment-verification assert over state the pre-generated snapshots already contain, so
    // they transact nothing and a per-shard error here fails them on principle — as an earlier
    // version of this guard did. Whether a *run* saw no transactions at all is the meaningful
    // signal, and assertMergedCoverageUsable checks that once the shards are merged.
    console.warn("  ⚠️  No transactions on these chains; this shard contributes no coverage.");
    return;
  }

  if (stats.traceFailures === stats.transactions) {
    throw new Error(
      `Coverage collection failed: all ${stats.transactions} transaction trace(s) errored. ` +
        "Is Anvil running with --steps-tracing (ANVIL_COVERAGE_MODE=1)?"
    );
  }
  if (stats.tracedContracts === 0) {
    throw new Error(
      `Coverage collection produced no trace data from ${stats.transactions} transaction(s) ` +
        `(${stats.traceFailures} trace call(s) failed). Refusing to write an empty report.`
    );
  }
  if (stats.hitSourceFiles === 0) {
    throw new Error(
      `Coverage collection traced ${stats.tracedContracts} contract(s) from ${stats.transactions} ` +
        "transaction(s) but mapped none of them to source lines. Refusing to write an empty report."
    );
  }
}

export async function collectChainTraces(rpcUrl: string, label: string): Promise<ChainTraceResult> {
  const provider = createProvider(rpcUrl);
  const contractPCs: ContractPCs = new Map();

  const blockNumber = await provider.getBlockNumber();
  console.log(`  📊 ${label}: scanning ${blockNumber} blocks...`);

  let totalTxs = 0;
  let traceFailures = 0;
  let totalOps = 0;

  for (let i = 0; i <= blockNumber; i++) {
    const block = await provider.getBlockWithTransactions(i);
    if (!block || block.transactions.length === 0) continue;

    for (const tx of block.transactions) {
      if (!tx.to && !tx.data) continue;

      const txHash = tx.hash;
      totalTxs++;

      try {
        const trace = (await provider.send("debug_traceTransaction", [
          txHash,
          { disableStorage: true, disableMemory: true, disableStack: false },
        ])) as TraceResult;

        if (!trace.structLogs || trace.structLogs.length === 0) continue;
        if (!tx.to) continue;

        const targetAddr = tx.to.toLowerCase();

        // depthStack[depth] = address of contract whose code is executing at that depth
        // depth 1 = tx.to
        const depthStack: Map<number, string> = new Map();
        depthStack.set(1, targetAddr);

        const addPCs = (addr: string, pc: number) => {
          let pcs = contractPCs.get(addr);
          if (!pcs) {
            pcs = new Set();
            contractPCs.set(addr, pcs);
          }
          pcs.add(pc);
          totalOps++;
        };

        for (const log of trace.structLogs) {
          const currentAddr = depthStack.get(log.depth);

          if (currentAddr) {
            addPCs(currentAddr, log.pc);
          }

          // When we see a CALL-family opcode, record the target for the next depth
          if (CALL_OPCODES.has(log.op)) {
            const callTarget = extractCallTarget(log);
            if (callTarget) {
              if (log.op === "DELEGATECALL" || log.op === "CALLCODE") {
                // For DELEGATECALL: code from callTarget runs in current context
                // PCs correspond to callTarget's bytecode
                depthStack.set(log.depth + 1, callTarget);
              } else {
                // For CALL/STATICCALL: execution moves to callTarget
                depthStack.set(log.depth + 1, callTarget);
              }
            }
          }
        }
      } catch (err: unknown) {
        traceFailures++;
        const msg = err instanceof Error ? err.message : String(err);
        console.warn(`  ⚠️  Failed to trace tx ${txHash}: ${msg}`);
      }
    }
  }

  console.log(
    `  📊 ${label}: traced ${totalTxs} transactions, ${totalOps} opcodes across ${contractPCs.size} contracts` +
      (traceFailures > 0 ? ` (${traceFailures} trace call(s) failed)` : "")
  );
  return { contractPCs, transactions: totalTxs, traceFailures };
}

/**
 * Merges trace data from multiple chains into a single map.
 * Keys are lowercase addresses; PCs are unioned.
 */
export function mergeTraces(traces: ContractPCs[]): ContractPCs {
  const merged: ContractPCs = new Map();

  for (const trace of traces) {
    for (const [addr, pcs] of trace) {
      let existing = merged.get(addr);
      if (!existing) {
        existing = new Set();
        merged.set(addr, existing);
      }
      for (const pc of pcs) {
        existing.add(pc);
      }
    }
  }

  return merged;
}
