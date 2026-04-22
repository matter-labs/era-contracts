import type { providers } from "ethers";
import { Contract, ContractFactory, Wallet, ethers } from "ethers";
import type { ContractInterface } from "@ethersproject/contracts";
import { impersonateAndRun } from "../core/utils";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  L2_BOOTLOADER_ADDR,
  L2_BRIDGEHUB_ADDR,
  L2_CHAIN_ASSET_HANDLER_ADDR,
  L2_COMPLEX_UPGRADER_ADDR,
  SYSTEM_CONTEXT_ADDR,
} from "../core/const";
import { getAbi, getBytecode, getCreationBytecode } from "../core/contracts";

// EIP-1967 storage slot for the admin of a TransparentUpgradeableProxy.
//   keccak256("eip1967.proxy.admin") - 1
const EIP1967_ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";

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
 * Deploy the `L2ChainAssetHandlerDev` implementation at `L2_CHAIN_ASSET_HANDLER_ADDR`
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

/**
 * Install the `L1ChainAssetHandlerDev` implementation behind the production
 * `L1ChainAssetHandler` TransparentUpgradeableProxy on L1 via the real upgrade
 * surface (no `anvil_setCode` on the impl slot, no storage writes).
 *
 * L1 `_getChainMigrationNumber(chainId)` reads `L1ChainAssetHandler.migrationNumber[chainId]`,
 * which production bumps via `bridgeMint` during the chain-level migrate-from-gateway
 * governance flow. That flow ultimately drives `Migrator.forwardedBridgeBurn` on the
 * migrating chain's Gateway diamond proxy, which enforces invariants
 * (`priorityTree.getSize() == 0`, `totalBatchesCommitted == totalBatchesExecuted`)
 * that a sequencer-less / prover-less Anvil harness cannot satisfy. The dev variant
 * exposes `setMigrationNumberForTesting(chainId, value)` so the harness can drive
 * the same observable transition through a real `onlyOwner`-gated call.
 *
 * L1ChainAssetHandler lives behind a `TransparentUpgradeableProxy` and has
 * immutables (`BRIDGEHUB`, `L1_CHAIN_ID`, `ETH_TOKEN_ASSET_ID`). We swap the
 * implementation pointer through the exact production upgrade path:
 *   1. Deploy a fresh `L1ChainAssetHandlerDev` on L1 (real constructor runs,
 *      baking the production immutable values in from `block.chainid` + the
 *      production bridgehub address).
 *   2. Read the proxy's EIP-1967 admin slot → the admin that controls upgrades
 *      (production `ProxyAdmin`).
 *   3. Impersonate that admin and call `proxy.upgradeTo(newImpl)` on the
 *      `ITransparentUpgradeableProxy` surface — identical to what
 *      `ProxyAdmin.upgrade(proxy, newImpl)` reaches in production.
 *
 * After the upgrade, the production proxy delegates into the Dev bytecode with
 * the production proxy's storage. Every inherited entry point keeps its
 * production semantics; `setMigrationNumberForTesting` becomes reachable to the
 * `onlyOwner` caller.
 */
export async function installL1ChainAssetHandlerDev(
  l1Provider: providers.JsonRpcProvider,
  bridgehubAddr: string
): Promise<string> {
  const bridgehub = new Contract(bridgehubAddr, getAbi("IL1Bridgehub"), l1Provider);
  const proxy: string = await bridgehub.chainAssetHandler();

  const deployer = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
  const factory = new ContractFactory(
    getAbi("L1ChainAssetHandlerDev"),
    getCreationBytecode("L1ChainAssetHandlerDev"),
    deployer
  );
  // The fresh deploy's constructor runs on L1, so `L1_CHAIN_ID` and
  // `ETH_TOKEN_ASSET_ID` are derived from `block.chainid` the same way production
  // derived them. `BRIDGEHUB` is passed explicitly and must match production.
  // `_owner` is inconsequential: the fresh deploy's storage is abandoned; after
  // the upgrade, `onlyOwner` checks run against the production proxy's storage.
  const freshDev = await factory.deploy(deployer.address, bridgehubAddr, { gasLimit: 8_000_000 });
  await freshDev.deployed();

  const adminSlotValue = await l1Provider.getStorageAt(proxy, EIP1967_ADMIN_SLOT);
  const admin = ethers.utils.getAddress("0x" + adminSlotValue.slice(26));

  const tup = new Contract(proxy, getAbi("ITransparentUpgradeableProxy"), l1Provider);
  await impersonateAndRun(l1Provider, admin, async (signer) => {
    const tx = await tup.connect(signer).upgradeTo(freshDev.address, { gasLimit: 500_000 });
    await tx.wait();
  });

  return proxy;
}

/**
 * Bump `L1ChainAssetHandler.migrationNumber[chainId]` via the dev setter installed
 * by {@link installL1ChainAssetHandlerDev}. Standing in for the production
 * `bridgeMint`-driven update that lands on L1 at the end of the chain-level
 * migrate-from-gateway flow.
 */
export async function setL1ChainMigrationNumber(params: {
  l1Provider: providers.JsonRpcProvider;
  chainAssetHandlerProxy: string;
  chainId: number;
  newMigrationNumber: number;
  gasLimit?: number;
}): Promise<void> {
  const { l1Provider, chainAssetHandlerProxy, chainId, newMigrationNumber, gasLimit = 1_000_000 } = params;

  const cah = new Contract(chainAssetHandlerProxy, getAbi("L1ChainAssetHandlerDev"), l1Provider);
  const owner: string = await cah.owner();

  await impersonateAndRun(l1Provider, owner, async (signer) => {
    const tx = await cah.connect(signer).setMigrationNumberForTesting(chainId, newMigrationNumber, { gasLimit });
    await tx.wait();
  });
}

/**
 * Flip `L1Bridgehub.settlementLayer[chainId]` back to `L1_CHAIN_ID` by calling
 * `forwardedBridgeMint` via the chain-asset-handler access surface.
 *
 * In production this runs at the end of the chain-level migrate-from-gateway
 * flow, when `L1ChainAssetHandler.bridgeMint` invokes
 * `L1Bridgehub.forwardedBridgeMint(...)`. Without it, L1 still routes
 * deposits/withdrawals for the chain through the L1→GW→L2 path (the
 * `settlementLayerChainId` encoded into withdrawal proofs picks the GW
 * `chainBalance` for decrement), so the downstream reverse-TBM withdrawal
 * lifecycle can't distinguish "pre-finalisation" from "post-finalisation".
 *
 * Idempotent with production state: every non-settlement-layer field
 * `forwardedBridgeMint` writes (`chainTypeManager`, `baseTokenAssetId`,
 * `assetIdIsRegistered`) was already set during chain registration and is
 * rewritten to the same value here.
 */
export async function completeL1ChainMigrationSettlementLayer(params: {
  l1Provider: providers.JsonRpcProvider;
  chainAssetHandlerProxy: string;
  bridgehubAddr: string;
  chainId: number;
  baseTokenAssetId: string;
  baseTokenOriginChainId: number;
  baseTokenOriginAddress: string;
  gasLimit?: number;
}): Promise<void> {
  const {
    l1Provider,
    chainAssetHandlerProxy,
    bridgehubAddr,
    chainId,
    baseTokenAssetId,
    baseTokenOriginChainId,
    baseTokenOriginAddress,
    gasLimit = 2_000_000,
  } = params;

  const bridgehub = new Contract(bridgehubAddr, getAbi("IL1Bridgehub"), l1Provider);
  const ctmAssetId: string = await bridgehub.ctmAssetIdFromChainId(chainId);

  await impersonateAndRun(l1Provider, chainAssetHandlerProxy, async (signer) => {
    const tx = await bridgehub.connect(signer).forwardedBridgeMint(
      ctmAssetId,
      chainId,
      {
        assetId: baseTokenAssetId,
        originChainId: baseTokenOriginChainId,
        originToken: baseTokenOriginAddress,
      },
      { gasLimit }
    );
    await tx.wait();
  });
}
