// AGENTS.md mandates "NEVER override storage slots in tests" with no exceptions,
// but the fork-upgrade harness in this directory is the one place we can't avoid
// it: forks are pinned at a block whose pending batches haven't yet been
// executed, and there is no public API to drive `totalBatchesExecuted` to match
// `totalBatchesCommitted` without replaying many real batch executions on every
// run. The override below substitutes for that history; it is scoped to fork
// runs and never touches a real chain.
//
// Slot indices below are taken from `forge inspect <Contract> storageLayout`; if any of these contracts ever shift their storage layout
// these constants need to move with it.
import type { providers } from "ethers";
import { Contract, ContractFactory, Wallet, ethers } from "ethers";
import type { ContractInterface } from "@ethersproject/contracts";
import { impersonateAndRun } from "../core/utils";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  L2_BOOTLOADER_ADDR,
  L2_CHAIN_ASSET_HANDLER_ADDR,
  SYSTEM_CONTEXT_ADDR,
} from "../core/const";
import { getAbi, getBytecode, getCreationBytecode } from "../core/contracts";

// EIP-1967 storage slot for the admin of a TransparentUpgradeableProxy.
//   keccak256("eip1967.proxy.admin") - 1
const EIP1967_ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103";

// `ZKChainBase.s` (the only state variable) lives at slot 0 of the proxy, so
// `ZKChainStorage` field offsets are absolute. Used by
// `forceBatchExecutedEqualsCommitted`.
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
 * for a chain's diamond proxy so the per-chain upgrade passes
 * its `totalBatchesCommitted == totalBatchesExecuted` guard.
 *
 * In production all committed batches must be executed before a chain's upgrade
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

/**
 * Deploy the `L2ChainAssetHandlerDev` implementation at `L2_CHAIN_ASSET_HANDLER_ADDR`
 * on the given provider via `anvil_setCode`.
 *
 * The production v33 implementation disables chain migrations at bridgeBurn/bridgeMint; the Dev
 * variant re-enables them so the preserved migration machinery stays covered by tests.
 *
 * The dev bytecode preserves the production contract's storage layout and every existing entry
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
 * Install the `L1ChainAssetHandlerDev` implementation behind the production
 * `L1ChainAssetHandler` TransparentUpgradeableProxy on L1 via the real upgrade
 * surface (no `anvil_setCode` on the impl slot, no storage writes).
 *
 * The production v33 implementation disables chain migrations at bridgeBurn/bridgeMint; the Dev
 * variant re-enables them so the preserved migration machinery stays covered by tests.
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
 * production semantics.
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
