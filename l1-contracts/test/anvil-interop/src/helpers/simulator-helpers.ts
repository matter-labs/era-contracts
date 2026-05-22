/**
 * Helpers for the Simulator + IMTFactRecorder + FlowAssetEscrow atomicity tests.
 *
 * These contracts are not part of the standard anvil-interop deployment, so the spec installs
 * them on demand via `anvil_setCode` at their canonical L2 addresses. Off-chain proof
 * construction (low-leaf lookup, merkle paths) lives here so the spec stays focused on
 * behavioral assertions.
 */

import { BigNumber, Contract, ethers, providers } from "ethers";
import { getAbi, getBytecode } from "../core/contracts";
import { impersonateAndRun } from "../core/utils";
import {
  L2_COMPLEX_UPGRADER_ADDR,
  L2_FLOW_ASSET_ESCROW_ADDR,
  L2_IMT_FACT_RECORDER_ADDR,
  L2_SIMULATOR_ADDR,
} from "../core/const";

/**
 * Install bytecode at a fixed L2 address. Idempotent across `--keep-chains` runs: presence of any
 * code at the address is treated as "already installed" and the call is a no-op.
 */
async function ensureCodeAt(
  provider: providers.JsonRpcProvider,
  address: string,
  contractName: "Simulator" | "IMTFactRecorder" | "FlowAssetEscrow"
): Promise<Contract> {
  const existingCode = await provider.getCode(address);
  if (existingCode === "0x" || existingCode === "0x0") {
    await provider.send("anvil_setCode", [address, getBytecode(contractName)]);
  }
  return new Contract(address, getAbi(contractName), provider);
}

/** Install + initialize Simulator, IMTFactRecorder, and FlowAssetEscrow. Returns all three. */
export async function deploySimulatorStack(provider: providers.JsonRpcProvider): Promise<{
  simulator: Contract;
  recorder: Contract;
  escrow: Contract;
}> {
  // Order matters: escrow has no init step, recorder + simulator do.
  const escrow = await ensureCodeAt(provider, L2_FLOW_ASSET_ESCROW_ADDR, "FlowAssetEscrow");

  const recorder = await ensureCodeAt(provider, L2_IMT_FACT_RECORDER_ADDR, "IMTFactRecorder");
  if ((await recorder.imtLeafCount()).eq(0)) {
    await impersonateAndRun(provider, L2_COMPLEX_UPGRADER_ADDR, async (signer) => {
      await (await (recorder.connect(signer) as Contract).initL2()).wait();
    });
  }

  const simulator = await ensureCodeAt(provider, L2_SIMULATOR_ADDR, "Simulator");
  // Simulator's `initL2` only sets the reentrancy guard; we treat presence-of-code as the canary
  // for "already initialized" in --keep-chains runs (matches the same pattern in
  // ensureCodeAt above).
  // We attempt init only on first install — detected by leafCount on the freshly installed
  // recorder above being zero before its init. As a separate safety net, the Simulator's
  // ReentrancyGuard.SlotOccupied revert would catch a double-init, surfacing it to the caller.
  if ((await provider.getCode(L2_SIMULATOR_ADDR)).length > 2) {
    // Probe storage for the reentrancy guard slot — keccak256("ReentrancyGuard") - 1 — to decide
    // whether init has run. Reading is cheap and avoids a try/catch around initL2.
    const RGUARD_SLOT = "0x8e94fed44239eb2314ab7a406345e6c5a8f0ccedf3b600de3d004e672c33abf4";
    const slotValue = await provider.send("eth_getStorageAt", [L2_SIMULATOR_ADDR, RGUARD_SLOT, "latest"]);
    const initialized = BigNumber.from(slotValue).gt(0);
    if (!initialized) {
      await impersonateAndRun(provider, L2_COMPLEX_UPGRADER_ADDR, async (signer) => {
        await (await (simulator.connect(signer) as Contract).initL2()).wait();
      });
    }
  }

  return { simulator, recorder, escrow };
}

/** Walk the IMT linked list to find the predecessor leaf index for `value`. */
export async function findLowLeafIndex(recorder: Contract, value: BigNumber): Promise<number> {
  let idx = 0;
  const leafCount = (await recorder.imtLeafCount()).toNumber();
  for (let step = 0; step < leafCount; step++) {
    const leaf = await recorder.imtLeafAt(idx);
    if (leaf.value.gte(value)) {
      throw new Error(`leaf ${idx} value ${leaf.value} is not strictly less than ${value}`);
    }
    const nextValue: BigNumber = leaf.nextValue;
    if (nextValue.eq(0) || nextValue.gt(value)) return idx;
    idx = leaf.nextIndex.toNumber();
  }
  throw new Error("walked off the end of the linked list");
}

/** Pull a Merkle proof + raw leaf for index `i` from the recorder. */
export async function loadProof(
  recorder: Contract,
  index: number
): Promise<{
  leaf: { value: BigNumber; nextIndex: BigNumber; nextValue: BigNumber };
  proof: string[];
}> {
  const leaf = await recorder.imtLeafAt(index);
  const proof: string[] = await recorder.imtMerklePath(index);
  return { leaf, proof };
}

/** `factValue(sender, fact)` — must match `FactHashing.factValue` in Solidity. */
export function factValue(sender: string, fact: string): BigNumber {
  const encoded = ethers.utils.defaultAbiCoder.encode(["address", "bytes32"], [sender, fact]);
  return BigNumber.from(ethers.utils.keccak256(encoded));
}
