import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import {
  AMSTERDAM_L1_BLOCK_GAS_LIMIT,
  ANVIL_DEFAULT_ACCOUNT_ADDR,
  EVM_PUSH_GAS,
  GLAMSTERDAM_CANARY_CALLDATA_BYTES,
  GLAMSTERDAM_CANARY_RUNTIME_BYTES,
  GLAMSTERDAM_COLD_STORAGE_ACCESS_GAS,
  GLAMSTERDAM_STORAGE_WRITE_GAS,
} from "../core/const";
import { glamsterdamIntrinsicGas, glamsterdamStateGas } from "../core/glamsterdam-gas";

// The L1 anvil under L1_GAS_RULES=amsterdam, pinned in .github/amsterdam-anvil.env.

export function resolveAmsterdamAnvilBinary(): string {
  const binary = process.env.ANVIL_AMSTERDAM_BIN?.trim();
  if (!binary) {
    throw new Error(
      "L1_GAS_RULES=amsterdam needs ANVIL_AMSTERDAM_BIN: install the pinned anvil with " +
        "scripts/install-amsterdam-anvil.sh <dir> and point ANVIL_AMSTERDAM_BIN at the path it prints"
    );
  }
  if (!fs.existsSync(binary)) {
    throw new Error(`ANVIL_AMSTERDAM_BIN=${binary} does not exist`);
  }
  return binary;
}

/**
 * An anvil state dump without its block history, at the Amsterdam L1's block gas limit. The pinned anvil's
 * `blocks` section does not parse in the Amsterdam build, and the dump's own `block.gas_limit` would override
 * `--gas-limit`.
 */
export function toAmsterdamStateDump(dump: Record<string, unknown>): Record<string, unknown> {
  const state = { ...dump };
  delete state.blocks;
  delete state.transactions;
  if (state.block !== undefined) {
    state.block = { ...(state.block as Record<string, unknown>), gas_limit: AMSTERDAM_L1_BLOCK_GAS_LIMIT };
  }
  return state;
}

/** Writes the Amsterdam copy of the dump at `loadStatePath` into the harness's outputs and returns its path. */
export function writeAmsterdamStateDump(loadStatePath: string, port: number): string {
  const outputPath = path.resolve(__dirname, "../../outputs", `l1-state-amsterdam-${port}.json`);
  fs.mkdirSync(path.dirname(outputPath), { recursive: true });
  const dump = JSON.parse(fs.readFileSync(loadStatePath, "utf-8")) as Record<string, unknown>;
  fs.writeFileSync(outputPath, JSON.stringify(toAmsterdamStateDump(dump)));
  return outputPath;
}

type CanaryEstimate = { what: string; gas: ethers.BigNumber; expected: number; isLowerBound?: boolean };

/**
 * Fails unless the started L1 runs Glamsterdam's gas schedule at the Amsterdam block gas limit: a build that
 * accepts `--hardfork amsterdam` without implementing it would otherwise measure the old rules without a word.
 * Between them the estimates exercise EIP-2780, EIP-7976, EIP-8037 and EIP-8038.
 */
export async function assertAmsterdamL1(provider: ethers.providers.JsonRpcProvider, binary: string): Promise<void> {
  const block = await provider.getBlock("latest");
  if (!block.gasLimit.eq(AMSTERDAM_L1_BLOCK_GAS_LIMIT)) {
    throw new Error(`Amsterdam L1: block gas limit ${block.gasLimit}, expected ${AMSTERDAM_L1_BLOCK_GAS_LIMIT}`);
  }

  const from = ANVIL_DEFAULT_ACCOUNT_ADDR;
  const to = ethers.utils.getAddress(
    ethers.utils.hexDataSlice(ethers.utils.id("anvil-interop amsterdam canary recipient"), 12)
  );
  const transfer = { from, to, value: 0, data: "0x" };
  const calldata = { from, to, value: 0, data: ethers.utils.hexZeroPad("0x", GLAMSTERDAM_CANARY_CALLDATA_BYTES) };
  const calldataGas = glamsterdamIntrinsicGas(calldata);
  // PUSH1 1, PUSH1 0, SSTORE: the constructor sets one new slot and deploys no runtime.
  const storeInitcode = "0x6001600055";
  const store = { from, to: null, value: 0, data: storeInitcode };
  // PUSH2 <size>, PUSH1 0, RETURN: deploys <size> zero bytes of runtime.
  const runtimeSize = ethers.utils.hexZeroPad(ethers.utils.hexlify(GLAMSTERDAM_CANARY_RUNTIME_BYTES), 2);
  const deploy = { from, to: null, value: 0, data: ethers.utils.hexConcat(["0x61", runtimeSize, "0x6000f3"]) };

  const estimates: CanaryEstimate[] = [
    {
      what: "a value-less transfer (EIP-2780)",
      gas: await provider.estimateGas(transfer),
      expected: glamsterdamIntrinsicGas(transfer).intrinsic,
    },
    {
      what: `${GLAMSTERDAM_CANARY_CALLDATA_BYTES} zero calldata bytes to an account (EIP-7976 floor)`,
      gas: await provider.estimateGas(calldata),
      expected: Math.max(calldataGas.intrinsic, calldataGas.floor),
    },
    {
      what: "a creation setting one new slot (EIP-8037 state gas, EIP-8038 STORAGE_WRITE)",
      gas: await provider.estimateGas({ from, data: storeInitcode }),
      expected:
        glamsterdamIntrinsicGas(store).intrinsic +
        glamsterdamStateGas({ newAccounts: 1, newCodeBytes: 0, newSlots: 1 }) +
        2 * EVM_PUSH_GAS +
        GLAMSTERDAM_COLD_STORAGE_ACCESS_GAS +
        GLAMSTERDAM_STORAGE_WRITE_GAS,
    },
    {
      what: `deploying ${GLAMSTERDAM_CANARY_RUNTIME_BYTES} bytes (EIP-8037 code deposit)`,
      gas: await provider.estimateGas({ from, data: deploy.data }),
      expected:
        glamsterdamIntrinsicGas(deploy).intrinsic +
        glamsterdamStateGas({ newAccounts: 1, newCodeBytes: GLAMSTERDAM_CANARY_RUNTIME_BYTES, newSlots: 0 }),
      isLowerBound: true,
    },
  ];

  const explain = (estimate: CanaryEstimate) =>
    `${estimate.what} estimates ${estimate.gas} gas, expected ${estimate.isLowerBound ? "at least " : ""}${estimate.expected}`;
  const wrong = estimates.filter((estimate) =>
    estimate.isLowerBound ? estimate.gas.lt(estimate.expected) : !estimate.gas.eq(estimate.expected)
  );
  if (wrong.length > 0) {
    throw new Error(
      `Amsterdam L1 canary: ${binary} does not apply Glamsterdam gas pricing: ${wrong.map(explain).join("; ")}. ` +
        "Pin a Foundry build that implements it in .github/amsterdam-anvil.env."
    );
  }
  console.log(`   Amsterdam L1 canary: ${estimates.map((estimate) => `${estimate.what} ${estimate.gas}`).join(", ")}`);
}
