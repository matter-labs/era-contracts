import type { providers } from "ethers";
import { Contract, ethers } from "ethers";
import type { ContractInterface } from "@ethersproject/contracts";
import { impersonateAndRun } from "../core/utils";
import { L2_BOOTLOADER_ADDR, SYSTEM_CONTEXT_ADDR } from "../core/const";
import { getAbi } from "../core/contracts";

// ZKChainStorage layout in the chain's diamond proxy. `s` (the only ZKChainBase
// state variable) lives at slot 0 of the proxy, so each `ZKChainStorage` field
// inherits the slot offset advertised in the comments of `ZKChainStorage.sol`.
// Used by `forceBatchExecutedEqualsCommitted` to satisfy the `NotAllBatchesExecuted`
// guard in `SettlementLayerV31UpgradeBase.upgrade`.
const ZK_CHAIN_TOTAL_BATCHES_EXECUTED_SLOT = 11;
const ZK_CHAIN_TOTAL_BATCHES_COMMITTED_SLOT = 13;

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
 * for a chain's diamond proxy so `SettlementLayerV31UpgradeBase.upgrade` passes
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
