/**
 * Harness-only stand-in for the L1SLOAD witness a ZKsync OS sequencer serves. Anvil L2s run `MockL1SloadPrecompile`
 * at the precompile address; {syncL1Reads} records an L1 anchor, imports it on each L2 through the real bootloader
 * entry point, and feeds the mock the `ChainRegistrationSender` slots as they are at that L1 block.
 */

import type { providers, BigNumber } from "ethers";
import { Contract, Wallet, ethers } from "ethers";
import { getAbi, getBytecode } from "../core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  CHAIN_REGISTRATION_SENDER_INTEROP_BASE_TOKEN_ASSET_ID_SLOT,
  CHAIN_REGISTRATION_SENDER_INTEROP_PEER_ALLOWED_SLOT,
  CHAIN_REGISTRATION_SENDER_INTEROP_SUSPENDED_SLOT,
  L1SLOAD_PRECOMPILE_ADDR,
  L1_BLOCK_HASH_IMPORT_ID,
  L2_BOOTLOADER_ADDR,
  L2_INTEROP_ROOT_STORAGE_ADDR,
} from "../core/const";
import type { CoreDeployedAddresses } from "../core/types";
import { impersonateAndRun } from "../core/utils";

/** An L1 block hash recorded by `L1MessageRoot`, as a chain imports it. */
export type L1Anchor = { blockNumber: number; blockHash: string; timestamp: BigNumber };

export type L1ReadsContext = {
  l1Provider: providers.JsonRpcProvider;
  l1Addresses: CoreDeployedAddresses;
  /** The chains whose gating slots are served, and whose L2s import the anchor. */
  chainIds: number[];
  l2Providers: Map<number, providers.JsonRpcProvider>;
};

function mappingSlot(_key: BigNumber | number | string, _slot: BigNumber | number | string): string {
  return ethers.utils.keccak256(ethers.utils.defaultAbiCoder.encode(["uint256", "uint256"], [_key, _slot]));
}

/** `L1View.interopPeerAllowedSlot`. */
export function interopPeerAllowedSlot(_chainId: number, _peerChainId: number): string {
  return mappingSlot(_peerChainId, mappingSlot(_chainId, CHAIN_REGISTRATION_SENDER_INTEROP_PEER_ALLOWED_SLOT));
}

/** `L1View.interopSuspendedSlot`. */
export function interopSuspendedSlot(_chainId: number): string {
  return mappingSlot(_chainId, CHAIN_REGISTRATION_SENDER_INTEROP_SUSPENDED_SLOT);
}

/** `L1View.interopBaseTokenAssetIdSlot`. */
export function interopBaseTokenAssetIdSlot(_chainId: number): string {
  return mappingSlot(_chainId, CHAIN_REGISTRATION_SENDER_INTEROP_BASE_TOKEN_ASSET_ID_SLOT);
}

/** Every `ChainRegistrationSender` slot the L2 contracts read for gating among `_chainIds`. */
export function gatingSlots(_chainIds: number[]): string[] {
  const slots: string[] = [];
  for (const chainId of _chainIds) {
    slots.push(interopSuspendedSlot(chainId), interopBaseTokenAssetIdSlot(chainId));
    for (const peerChainId of _chainIds.filter((id) => id !== chainId)) {
      slots.push(interopPeerAllowedSlot(chainId, peerChainId));
    }
  }
  return slots;
}

/**
 * Installs the mock precompile on an L2 whose state predates it (an upgraded chain). Fresh chains get it as a
 * predeploy.
 */
export async function installL1SloadMock(_l2Provider: providers.JsonRpcProvider): Promise<void> {
  await _l2Provider.send("anvil_setCode", [L1SLOAD_PRECOMPILE_ADDR, getBytecode("MockL1SloadPrecompile")]);
}

/**
 * Moves the L1 clock up to the L2s' if it is behind: freshness compares the anchor's L1 time with L2 block time, and an
 * L1 loaded from a dump without its blocks (the Amsterdam L1) restarts its clock near zero.
 */
async function alignL1Clock(
  _l1Provider: providers.JsonRpcProvider,
  _l2Providers: providers.JsonRpcProvider[]
): Promise<void> {
  const l1Time = (await _l1Provider.getBlock("latest")).timestamp;
  const l2Times = await Promise.all(
    _l2Providers.map(async (provider) => (await provider.getBlock("latest")).timestamp)
  );
  const l2Time = Math.max(...l2Times);
  if (l1Time < l2Time) {
    await _l1Provider.send("evm_setNextBlockTimestamp", [l2Time]);
  }
}

/** Records the previous L1 block's hash on L1, as every `commitBatches` does on a real chain. */
export async function recordL1Anchor(
  _l1Provider: providers.JsonRpcProvider,
  _l1Addresses: CoreDeployedAddresses
): Promise<L1Anchor> {
  const wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, _l1Provider);
  const messageRoot = new Contract(_l1Addresses.messageRoot, getAbi("L1MessageRoot"), wallet);
  const receipt = await (await messageRoot.recordL1BlockHash()).wait();
  const blockNumber = receipt.blockNumber - 1;
  const recorded = await messageRoot.recordedL1BlockHash(blockNumber);
  if (recorded.root === ethers.constants.HashZero) {
    throw new Error(`L1 block ${blockNumber} was not recorded`);
  }
  return { blockNumber, blockHash: recorded.root, timestamp: recorded.timestamp };
}

/** Imports `_anchor` on an L2 the way the bootloader does. */
export async function importL1Anchor(_l2Provider: providers.JsonRpcProvider, _anchor: L1Anchor): Promise<void> {
  const rootStorage = new Contract(L2_INTEROP_ROOT_STORAGE_ADDR, getAbi("L2InteropRootStorage"), _l2Provider);
  await impersonateAndRun(_l2Provider, L2_BOOTLOADER_ADDR, async (signer) => {
    const tx = await rootStorage.connect(signer).addSingleInteropRoot({
      chainId: L1_BLOCK_HASH_IMPORT_ID,
      blockOrBatchNumber: _anchor.blockNumber,
      timestamp: _anchor.timestamp,
      sides: [_anchor.blockHash],
    });
    await tx.wait();
  });
  if ((await rootStorage.l1AnchorBlockHash()) !== _anchor.blockHash) {
    throw new Error(`L2 at ${_l2Provider.connection.url} did not import the anchor of L1 block ${_anchor.blockNumber}`);
  }
}

/**
 * Takes a new anchor and makes every chain in `_context` read L1 at it: the chains see every L1 gating change made
 * before this call.
 */
export async function syncL1Reads(_context: L1ReadsContext): Promise<L1Anchor> {
  const { l1Provider, l1Addresses, chainIds, l2Providers } = _context;
  await alignL1Clock(l1Provider, [...l2Providers.values()]);
  const anchor = await recordL1Anchor(l1Provider, l1Addresses);
  const sender = l1Addresses.chainRegistrationSender;
  const keys = gatingSlots(chainIds);
  const values = await Promise.all(keys.map((key) => l1Provider.getStorageAt(sender, key, anchor.blockNumber)));

  for (const chainId of chainIds) {
    const l2Provider = l2Providers.get(chainId);
    if (!l2Provider) {
      throw new Error(`No L2 provider for chain ${chainId}`);
    }
    await importL1Anchor(l2Provider, anchor);
    const mock = new Contract(
      L1SLOAD_PRECOMPILE_ADDR,
      getAbi("MockL1SloadPrecompile"),
      new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l2Provider)
    );
    await (await mock.setL1StorageValues(sender, keys, values)).wait();
  }
  console.log(`   ✅ Chains ${chainIds.join(", ")} read L1 at block ${anchor.blockNumber}`);
  return anchor;
}
