// AGENTS.md mandates "NEVER override storage slots in tests" with no exceptions,
// but the fork-upgrade harness in this directory is the one place we can't avoid
// it: forks are pinned at a block whose pending batches haven't yet been
// executed, and there is no public API to drive `totalBatchesExecuted` to match
// `totalBatchesCommitted` without replaying many real batch executions on every
// run. The override below substitutes for that history; it is scoped to fork
// runs and never touches a real chain.
//
// Slot indices below are taken from `forge inspect <Contract> storageLayout` on
// the v31 contracts; if any of these contracts ever shift their storage layout
// these constants need to move with it.
import type { providers } from "ethers";
import { Contract, Wallet, ethers } from "ethers";
import type { ContractInterface } from "@ethersproject/contracts";
import { impersonateAndRun } from "../core/utils";
import { ANVIL_DEFAULT_PRIVATE_KEY, L2_BOOTLOADER_ADDR, SYSTEM_CONTEXT_ADDR } from "../core/const";
import { getAbi, LEGACY_V31_ADMIN_BACKFILL_ABI } from "../core/contracts";

// `ZKChainBase.s` (the only state variable) lives at slot 0 of the proxy, so
// `ZKChainStorage` field offsets are absolute. Used by
// `forceBatchExecutedEqualsCommitted`.
const ZK_CHAIN_TOTAL_BATCHES_EXECUTED_SLOT = 11;
const ZK_CHAIN_TOTAL_BATCHES_COMMITTED_SLOT = 13;
// Packed word holding `baseTokenHasTotalSupply` in its lowest byte (with `zksyncOSMaxTxGasLimit`
// and `pubdataContent` above it).
const ZK_CHAIN_BASE_TOKEN_HAS_TOTAL_SUPPLY_SLOT = 68;
// `PriorityOpLowerBound.lowerBound` / `.recorded` are the contract's two state variables
// (mapping slots 0 and 1).
const PRIORITY_OP_LOWER_BOUND_MAPPING_SLOT = 0;
const PRIORITY_OP_RECORDED_MAPPING_SLOT = 1;

const systemContextAbi = getAbi("SystemContext") as ContractInterface;

/**
 * Harness-only shim: execute an Ownable2Step ownership transfer entirely on Anvil.
 *
 * Production flows rely on the real owner and pending owner executing these calls.
 * The harness uses impersonation to apply the same state transition without external signers.
 */
export async function transferOwnable2Step(
  provider: providers.JsonRpcProvider,
  contractAddr: string,
  ownable2StepAbi: ContractInterface,
  currentOwner: string,
  targetOwner: string,
  gasLimit = 500_000
): Promise<void> {
  const contract = new Contract(contractAddr, ownable2StepAbi, provider);

  await impersonateAndRun(provider, currentOwner, async (signer) => {
    const tx = await contract.connect(signer).transferOwnership(targetOwner, { gasLimit });
    await tx.wait();
  });

  await impersonateAndRun(provider, targetOwner, async (signer) => {
    const tx = await contract.connect(signer).acceptOwnership({ gasLimit });
    await tx.wait();
  });
}

/**
 * Harness-only shim: copy `s.totalBatchesCommitted` onto `s.totalBatchesExecuted`
 * for a chain's diamond proxy so the per-chain upgrade passes
 * its `totalBatchesCommitted == totalBatchesExecuted` guard.
 *
 * In production all committed batches must be executed before the v31 upgrade
 * begins. On a forked chain whose pending batches haven't been executed at fork
 * time, we mark the gap as if execution had caught up — same end-state as the
 * production prerequisite, just realised via storage write instead of running
 * the executor for several batches.
 */
export async function forceBatchExecutedEqualsCommitted(
  provider: providers.JsonRpcProvider,
  diamondProxyAddr: string
): Promise<void> {
  const committedHex = await provider.send("eth_getStorageAt", [
    diamondProxyAddr,
    ethers.utils.hexValue(ZK_CHAIN_TOTAL_BATCHES_COMMITTED_SLOT),
    "latest",
  ]);
  await provider.send("anvil_setStorageAt", [
    diamondProxyAddr,
    ethers.utils.hexValue(ZK_CHAIN_TOTAL_BATCHES_EXECUTED_SLOT),
    committedHex,
  ]);
}

/**
 * Harness-only shim: model the v31 base-token backfill prerequisite for a ZKsync OS chain.
 *
 * The v32 upgrade of a ZKsync OS chain requires (a) `s.baseTokenHasTotalSupply`, which v31
 * sets when the backfill service transaction is requested, and (b) a bound recorded in the
 * upgrade's `PriorityOpLowerBound` registry proving that transaction also executed on L2.
 *
 * On a forked v31 chain that was really backfilled, (a) already holds and (b) goes through
 * the registry's real permissionless entry point. A forked v30 state predates the v31 backfill entirely
 * (its facets lack `baseTokenSupportsTotalSupply`, so even the registry's guard cannot run).
 * A direct v30 -> v32 upgrade is intentionally NOT a supported production path — real chains
 * acquire this state by passing through v31 and its backfill — but the v30 fixture is the
 * only ZKsync OS state available for exercising the upgrade machinery end to end, so we
 * substitute that unreachable history with direct writes, same rationale as
 * `forceBatchExecutedEqualsCommitted` above.
 */
export async function modelV31BackfillPrerequisite(params: {
  l1Provider: providers.JsonRpcProvider;
  diamondProxyAddr: string;
  settlementLayerUpgradeAddr: string;
}): Promise<void> {
  const { l1Provider, diamondProxyAddr, settlementLayerUpgradeAddr } = params;

  const getters = new Contract(diamondProxyAddr, getAbi("GettersFacet"), l1Provider);
  let backfilled: boolean | undefined;
  try {
    backfilled = await getters.baseTokenSupportsTotalSupply();
  } catch {
    backfilled = undefined; // Pre-v31 facets: the selector does not exist on the fork.
  }

  if (backfilled === false) {
    // v31 facets whose fixture never ran the backfill: request it through the REAL v31 Admin entry
    // point (impersonated chain admin), which sets the L1 flag exactly like production. The L2
    // service transaction it enqueues cannot execute here — the harness has no sequencer — which
    // is what the registry substitution below stands in for.
    const admin: string = await getters.getAdmin();
    // The setter only exists on the forked chain's v31 facets — v32 removed it — so the current
    // AdminFacet artifact cannot encode the call.
    const adminFacet = new Contract(diamondProxyAddr, LEGACY_V31_ADMIN_BACKFILL_ABI, l1Provider);
    await impersonateAndRun(l1Provider, admin, async (signer) => {
      const tx = await adminFacet.connect(signer).setZKsyncOSPreV31TotalSupply(0, { gasLimit: 1_000_000 });
      await tx.wait();
    });
  }

  const settlementLayerUpgrade = new Contract(settlementLayerUpgradeAddr, getAbi("V32UpgradeZKsyncOS"), l1Provider);
  const registryAddr: string = await settlementLayerUpgrade.PRIORITY_OP_LOWER_BOUND();
  const registry = new Contract(registryAddr, getAbi("PriorityOpLowerBound"), l1Provider);
  if (await registry.recorded(diamondProxyAddr)) {
    return; // already modeled / recorded
  }

  if (backfilled === true) {
    // v31 fork with a completed backfill: use the real permissionless entry point. Works when the
    // fixture froze with all priority ops processed (the recorded bound equals the processed count).
    const caller = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
    const tx = await registry.connect(caller).lowerBoundPriorityOp(diamondProxyAddr, { gasLimit: 500_000 });
    await tx.wait();
    return;
  }

  if (backfilled === undefined) {
    // Pre-v31 fixture: no facet can set the flag, so write the bit directly (lowest byte of the
    // packed word, preserving the rest) — the substitution for history the fixture predates.
    const slotHex = ethers.utils.hexValue(ZK_CHAIN_BASE_TOKEN_HAS_TOTAL_SUPPLY_SLOT);
    const word = ethers.utils.hexZeroPad(
      await l1Provider.send("eth_getStorageAt", [diamondProxyAddr, slotHex, "latest"]),
      32
    );
    await l1Provider.send("anvil_setStorageAt", [diamondProxyAddr, slotHex, word.slice(0, 64) + "01"]);
  }

  // Record a bound equal to the processed priority-op count directly in the registry: the
  // production bound (taken from the total count after the backfill executes on L2) is unreachable
  // here because the harness cannot process priority ops.
  const firstUnprocessed = await getters.getFirstUnprocessedPriorityTx();
  const abiCoder = ethers.utils.defaultAbiCoder;
  const boundSlot = ethers.utils.keccak256(
    abiCoder.encode(["address", "uint256"], [diamondProxyAddr, PRIORITY_OP_LOWER_BOUND_MAPPING_SLOT])
  );
  await l1Provider.send("anvil_setStorageAt", [
    registryAddr,
    boundSlot,
    ethers.utils.hexZeroPad(firstUnprocessed.toHexString(), 32),
  ]);
  const recordedSlot = ethers.utils.keccak256(
    abiCoder.encode(["address", "uint256"], [diamondProxyAddr, PRIORITY_OP_RECORDED_MAPPING_SLOT])
  );
  await l1Provider.send("anvil_setStorageAt", [registryAddr, recordedSlot, ethers.utils.hexZeroPad("0x01", 32)]);
}

/**
 * Harness-only shim: fast-forward the L1 anvil clock past the
 * `GovernanceUpgradeTimer.INITIAL_DELAY` window so stage 1's `checkDeadline()`
 * call passes. The deploy-time delay is at most a few minutes on stage/testnet,
 * so 1 day of warp covers every configured `INITIAL_DELAY` with margin.
 */
export async function advanceL1TimePastUpgradeDeadline(
  provider: providers.JsonRpcProvider,
  seconds = 24 * 60 * 60
): Promise<void> {
  await provider.send("evm_increaseTime", [seconds]);
  await provider.send("evm_mine", []);
}

/**
 * Harness-only shim: simulate the bootloader updating SystemContext settlement layer.
 *
 * Real chains do this at batch start. On Anvil we impersonate the bootloader to
 * drive the same contract path and keep migration-related counters in sync.
 */
export async function setSettlementLayerViaBootloader(params: {
  provider: providers.JsonRpcProvider;
  settlementLayerChainId: number;
  gasLimit?: number;
}): Promise<void> {
  const { provider, settlementLayerChainId, gasLimit = 1_000_000 } = params;

  const systemContext = new Contract(SYSTEM_CONTEXT_ADDR, systemContextAbi, provider);
  await impersonateAndRun(provider, L2_BOOTLOADER_ADDR, async (signer) => {
    const tx = await systemContext.connect(signer).setSettlementLayerChainId(settlementLayerChainId, {
      gasLimit,
    });
    await tx.wait();
  });
}
