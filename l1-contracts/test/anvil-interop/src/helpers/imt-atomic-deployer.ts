/**
 * Deployment helper for the L1-free atomic-interop stack (bundle model).
 *
 * Installs, on each participating L2 anvil chain, the canonical built-in contract set:
 *   - {L2InteropCommitmentTree} at L2_INTEROP_COMMITMENT_TREE_ADDR (0x10012),
 *   - {AtomicFlowManager}       at L2_ATOMIC_FLOW_MANAGER_ADDR      (0x10014),
 * then seeds the commitment tree exactly as the on-chain genesis force-deployment would:
 *   - tree.initialize()  (one-time IMT seed; no wiring args).
 * All cross-contract wiring is referenced by canonical fixed address in the contracts themselves — the
 * tree's appender, the manager's tree / asset router / interop center / interop handler, and the
 * L2AssetRouter's recognition of the manager (`_atomicFlowManagerAddr()` -> L2_ATOMIC_FLOW_MANAGER_ADDR)
 * — so there is no manager initialization and no explicit registration step.
 *
 * Unlike the removed escrow-direct flow, the manager is fund-touchless: the source-side burn happens
 * through the normal interop path ({InteropCenter.sendBundle} -> {L2AssetRouter.initiateIndirectCall}),
 * and the destination mint is driven by {InteropHandler.executeAtomicBundle}. The manager only appends
 * commit values to the IMT (`append`, called by the InteropCenter) and drives `recoverAtomicCall` on
 * the timeout path.
 *
 * Contracts are installed at their canonical addresses via `anvil_setCode` (the established harness
 * pattern for built-ins; storage is NOT poked — all state comes from real `initialize` calls). The
 * commitment tree publishing pins the message sender to the canonical 0x10012, and the on-chain proof
 * library reconstructs that same address, so installing at the canonical slots keeps the harness
 * faithful to the design. (Root-message authentication itself is mocked on anvil via
 * {MockL2MessageVerification} at L2_MESSAGE_VERIFICATION_ADDR.)
 */

import type { providers } from "ethers";
import { Contract, Wallet, ethers } from "ethers";
import { getAbi, getBytecode } from "../core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  INTEROP_CENTER_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_ATOMIC_FLOW_MANAGER_ADDR,
  L2_INTEROP_COMMITMENT_TREE_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
} from "../core/const";

export interface AtomicStack {
  chainId: number;
  provider: providers.JsonRpcProvider;
  /** {L2InteropCommitmentTree} at the canonical 0x10012. */
  tree: Contract;
  /** {AtomicFlowManager} at the canonical 0x10014. */
  manager: Contract;
  /** {InteropCenter} at the canonical 0x1000d (the atomic SEND entry point). */
  interopCenter: Contract;
  /** {InteropHandler} at the canonical 0x1000e (the atomic RECEIVE entry point). */
  interopHandler: Contract;
}

/**
 * Install + wire the atomic stack on one L2 chain.
 *
 * Idempotent: if the manager is already initialized (re-run against the same loaded chain state) the
 * wiring steps are skipped. `assetRouter` / `nativeTokenVault` default to the system predeploys, which
 * is what the anvil harness uses.
 */
export async function deployAtomicStack(args: {
  chainId: number;
  provider: providers.JsonRpcProvider;
  assetRouter?: string;
  nativeTokenVault?: string;
}): Promise<AtomicStack> {
  const { chainId, provider } = args;
  const assetRouter = args.assetRouter ?? L2_ASSET_ROUTER_ADDR;
  const nativeTokenVault = args.nativeTokenVault ?? L2_NATIVE_TOKEN_VAULT_ADDR;
  const wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);

  // 1. Install runtime bytecode at the canonical addresses.
  await provider.send("anvil_setCode", [L2_INTEROP_COMMITMENT_TREE_ADDR, getBytecode("L2InteropCommitmentTree")]);
  await provider.send("anvil_setCode", [L2_ATOMIC_FLOW_MANAGER_ADDR, getBytecode("AtomicFlowManager")]);

  // 1b. Refresh the InteropCenter / InteropHandler runtime code if the pre-generated chain states
  // predate the atomic-interop additions (the `atomicBundle` ERC-7786 attribute + `_dispatchBundle`
  // append path on the center, `executeAtomicBundle` on the handler). Code-only upgrade: the atomic
  // logic reuses the existing storage layout (no slot is added/reordered; the manager address is a
  // hardcoded constant), so `anvil_setCode` preserves L1_CHAIN_ID / nonces / fees / bundleStatus. This
  // is the same built-in-install pattern used for the AR / NTV below.
  //   InteropCenter probe: the `atomicBundle` attribute selector (0xfc53bac1) embedded in
  //     `parseAttributes`. InteropHandler probe: the `executeAtomicBundle` selector (0xf6b6a4e9).
  if (!(await hasSelector(provider, INTEROP_CENTER_ADDR, "0xfc53bac1"))) {
    await provider.send("anvil_setCode", [INTEROP_CENTER_ADDR, getBytecode("InteropCenter")]);
  }
  if (
    !(await hasSelector(
      provider,
      L2_INTEROP_HANDLER_ADDR,
      selectorOf(
        "executeAtomicBundle(bytes,(bytes32,uint64,bytes32[],uint256[],(uint256,uint256,bytes32,uint16,uint256,bytes32[],(uint256,uint256,uint256),uint256,bytes32[])[]))"
      )
    ))
  ) {
    await provider.send("anvil_setCode", [L2_INTEROP_HANDLER_ADDR, getBytecode("InteropHandler")]);
  }

  const tree = new Contract(L2_INTEROP_COMMITMENT_TREE_ADDR, getAbi("L2InteropCommitmentTree"), wallet);
  const manager = new Contract(L2_ATOMIC_FLOW_MANAGER_ADDR, getAbi("AtomicFlowManager"), wallet);
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), wallet);
  const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("InteropHandler"), wallet);

  // 2. Seed the commitment tree's IMT if not already seeded (supports re-runs over loaded chain state).
  //    All cross-contract wiring — the tree's appender and the manager's tree / asset router / interop
  //    center / interop handler — is referenced by canonical fixed address in the contracts themselves,
  //    so there is no manager initialization step and `tree.initialize()` takes no arguments.
  const treeLeafCount = await tree.leafCount();
  if (treeLeafCount.eq(0)) {
    await (await tree.initialize()).wait();
  }

  // 3. Refresh the L2AssetRouter runtime code if it predates the atomic-flow additions.
  //
  // The pre-generated chain states were dumped before the AR's atomic-flow additions
  // (`recoverAtomicCall`, plus auth that recognises the canonical AtomicFlowManager at
  // `L2_ATOMIC_FLOW_MANAGER_ADDR`), so refresh the AR's runtime code in place to the freshly-built
  // bytecode. This is a CODE upgrade only — the AR's storage is preserved, and the atomic-flow auth
  // keys off a fixed address (`_atomicFlowManagerAddr()`) rather than storage, so nothing needs wiring.
  // Same `anvil_setCode` built-in-install pattern the harness uses elsewhere. Selectors are computed
  // from the literal signatures (not via a loaded ABI): the committed zkstack-out ABIs can lag the
  // freshly-rebuilt contracts, so signature-derived selectors are the reliable probe.
  if (!(await hasSelector(provider, assetRouter, selectorOf("recoverAtomicCall(uint256,bytes)")))) {
    await provider.send("anvil_setCode", [assetRouter, getBytecode("L2AssetRouter")]);
  }

  // Likewise, refresh the L2NativeTokenVault if it predates `bridgeRecoverFailedTransfer` (the refund
  // path the manager drives via `recoverAtomicCall`). Code-only upgrade: the recover path reuses the
  // existing NTV storage (bridgedTokenBeacon / originChainId / tokenAddress / chainBalance), which is
  // identical between the standard and dev variants, so no slot is overwritten. We install the
  // `L2NativeTokenVaultDev` runtime — the variant the anvil harness deploys — because its
  // `_deployBeaconProxy` uses standard-EVM CREATE2 (works on Anvil), whereas the standard
  // `L2NativeTokenVault` routes through the system contract deployer (not supported by the Anvil mock).
  if (
    !(await hasSelector(provider, nativeTokenVault, selectorOf("bridgeRecoverFailedTransfer(uint256,bytes32,bytes)")))
  ) {
    await provider.send("anvil_setCode", [nativeTokenVault, getBytecode("L2NativeTokenVaultDev")]);
  }

  // No manager registration step: the AR recognises the canonical AtomicFlowManager by its fixed
  // address (`_atomicFlowManagerAddr()` -> L2_ATOMIC_FLOW_MANAGER_ADDR), installed at step 1 above.

  return { chainId, provider, tree, manager, interopCenter, interopHandler };
}

/**
 * Whether the deployed contract at `address` exposes the function with selector `selector` — detected
 * by scanning its runtime code for the 4-byte selector (no eth_call, so no error to swallow). Lets the
 * deployer detect whether a pre-generated chain state predates a contract's newer functions and needs
 * a code refresh.
 */
async function hasSelector(provider: providers.JsonRpcProvider, address: string, selector: string): Promise<boolean> {
  const code: string = (await provider.getCode(address)).toLowerCase();
  return code.includes(selector.slice(2).toLowerCase());
}

/** 4-byte function selector for a canonical signature string, e.g. `selectorOf("recoverAtomicCall(uint256,bytes)")`. */
function selectorOf(signature: string): string {
  return ethers.utils.id(signature).slice(0, 10);
}

/** Install + wire the atomic stack on each provided L2 chain. Returns a chainId → stack map. */
export async function deployAtomicStacksForChains(
  chains: Array<{ chainId: number; provider: providers.JsonRpcProvider }>
): Promise<Record<number, AtomicStack>> {
  const out: Record<number, AtomicStack> = {};
  // Sequential: each touches a different anvil, but keep it simple/deterministic.
  for (const c of chains) {
    out[c.chainId] = await deployAtomicStack(c);
  }
  return out;
}
