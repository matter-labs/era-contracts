import type { providers } from "ethers";
import { Contract } from "ethers";
import type { ContractInterface } from "@ethersproject/contracts";
import { impersonateAndRun } from "../core/utils";
import {
  L2_BOOTLOADER_ADDR,
  L2_BRIDGEHUB_ADDR,
  L2_CHAIN_ASSET_HANDLER_ADDR,
  L2_COMPLEX_UPGRADER_ADDR,
  SYSTEM_CONTEXT_ADDR,
} from "../core/const";
import { getAbi, getBytecode } from "../core/contracts";

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

/**
 * Install the `L2ChainAssetHandlerDev` implementation at `L2_CHAIN_ASSET_HANDLER_ADDR`
 * on the given provider via `anvil_setCode`.
 *
 * Reverse TBM testing needs to drive the chain's `migrationNumber` counter on the
 * Gateway without going through the production `bridgeBurn` → `Migrator.forwardedBridgeBurn`
 * path, which enforces `priorityTree.getSize() == 0` and `totalBatchesCommitted ==
 * totalBatchesExecuted`. The Anvil harness has no sequencer and no proving flow, so the
 * priority tree is never drained and the committed/executed counters are never advanced.
 *
 * The dev variant exposes a small `setMigrationNumberForTesting` setter (gated by
 * `onlyUpgrader`, same modifier as the production update paths) so the harness can move
 * the counter through a real Solidity call instead of rewriting storage slots. The dev
 * bytecode preserves the production contract's storage layout and every existing entry
 * point, so installing it at the production address leaves all non-test flows unchanged.
 */
export async function installL2ChainAssetHandlerDev(provider: providers.JsonRpcProvider): Promise<void> {
  const devBytecode = getBytecode("L2ChainAssetHandlerDev");
  if (!devBytecode || devBytecode === "0x") {
    throw new Error(
      "L2ChainAssetHandlerDev bytecode missing — ensure `forge build contracts/dev-contracts/L2ChainAssetHandlerDev.sol` ran"
    );
  }
  await provider.send("anvil_setCode", [L2_CHAIN_ASSET_HANDLER_ADDR, devBytecode]);
}

/**
 * Harness-only shim: reproduce the Gateway-side state transition that the Gateway
 * sequencer would apply when processing the L1→GW priority tx of
 * `GatewayPreparation.startMigrateChainFromGateway`.
 *
 * Production reverse-migration sequence (end-to-end) is:
 *   1. L1 chain admin runs the `GatewayPreparation.startMigrateChainFromGateway`
 *      Forge script → submits an L1→GW priority tx targeting the GW L2 chain admin
 *      with `L2AssetRouter.withdraw(ctmAssetId, BridgehubBurnCTMAssetData)` calldata.
 *   2. The Gateway sequencer picks up the priority tx → GW L2 chain admin → GW
 *      `L2AssetRouter.withdraw` → GW `L2ChainAssetHandler.bridgeBurn` → bridgehub
 *      `forwardedBridgeBurnSetSettlementLayer` + `migrationNumber[chainId]++`.
 *   3. A GW→L1 message is emitted and later finalised on L1.
 *
 * The Anvil harness cannot execute step 2 natively: it has no sequencer to drain the
 * GW diamond's priority tree (required by `Migrator.forwardedBridgeBurn`) and no
 * batch commit/execute flow to satisfy the `totalBatchesCommitted == totalBatchesExecuted`
 * invariant. Rather than fake these invariants at the contract layer, we reproduce the
 * two observable state transitions directly through real Solidity entry points:
 *
 *   - `forwardedBridgeBurnSetSettlementLayer` on the GW `L2Bridgehub`, gated by
 *     `onlyChainAssetHandler` → impersonated from `L2_CHAIN_ASSET_HANDLER_ADDR`, exactly
 *     how the production `bridgeBurn` call reaches it.
 *   - `setMigrationNumberForTesting` on the dev variant of `L2ChainAssetHandler`, gated
 *     by `onlyUpgrader` → impersonated from `L2_COMPLEX_UPGRADER_ADDR`, matching the
 *     access surface of every other `onlyUpgrader`-gated setter on this contract.
 *
 * Prereq: `installL2ChainAssetHandlerDev(gwProvider)` must have been called first so
 * that `setMigrationNumberForTesting` is reachable.
 */
export async function simulateGWChainMigrationBurn(params: {
  gwProvider: providers.JsonRpcProvider;
  chainId: number;
  newSettlementLayerChainId: number;
  newMigrationNumber: number;
  gasLimit?: number;
}): Promise<void> {
  const { gwProvider, chainId, newSettlementLayerChainId, newMigrationNumber, gasLimit = 1_000_000 } = params;

  const bridgehub = new Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), gwProvider);
  await impersonateAndRun(gwProvider, L2_CHAIN_ASSET_HANDLER_ADDR, async (signer) => {
    const tx = await bridgehub
      .connect(signer)
      .forwardedBridgeBurnSetSettlementLayer(chainId, newSettlementLayerChainId, { gasLimit });
    await tx.wait();
  });

  const chainAssetHandler = new Contract(L2_CHAIN_ASSET_HANDLER_ADDR, getAbi("L2ChainAssetHandlerDev"), gwProvider);
  await impersonateAndRun(gwProvider, L2_COMPLEX_UPGRADER_ADDR, async (signer) => {
    const tx = await chainAssetHandler
      .connect(signer)
      .setMigrationNumberForTesting(chainId, newMigrationNumber, { gasLimit });
    await tx.wait();
  });
}
