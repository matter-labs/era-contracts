#!/usr/bin/env node

/**
 * Atomic interop on real testnets — phase-by-phase deployer + runner.
 *
 *   Source: creator_testnet (278701)   ─┐
 *                                       ├── settle via L1FlowLinker on Sepolia
 *   Source: zksync_os_testnet (8022833) ─┘
 *
 * Both chains run zksync-os v0.30.1 and settle on Sepolia (chainId 11155111).
 *
 * Usage:
 *   PK=$(cat ~/.test_pk) npx ts-node test/anvil-interop/atomic-interop-testnet.ts <phase>
 *
 * Phases (run one at a time; each persists state to outputs/atomic-interop-testnet.json):
 *
 *   preflight     - verify wallet balances + chain reachability
 *   bridge-eth    - deposit gas-fee ETH from Sepolia to both L2s
 *   deploy-l2     - deploy escrow (nonce-0) + private interop stack on each L2
 *   wire-l2       - initialize private stack, cross-register routers, set escrow
 *   deploy-l1     - deploy L1FlowLinker on Sepolia + initialize canonical escrow
 *   tokens        - deploy + register test ERC20 on each L2, mint to test recipient
 *   commit        - approve + commitSend on each L2, register flow on linker
 *   wait-verify   - poll until both commit batches are executed on Sepolia
 *   finalize      - recordFinalitySignal on L1 with real Merkle proofs
 *   execute       - executeFlow on L1 (dispatches authorize priority txs)
 *   wait-l2       - poll until authorize priority txs land on each L2
 *   settle        - execute() on each L2 to perform the burn / mint
 *   verify        - check final balances + flow state
 *
 *   status        - dump current state file
 *   reset         - wipe state file (use with care)
 */

import * as fs from "fs";
import * as path from "path";
import { BigNumber, Contract, ContractFactory, ethers, providers, Wallet } from "ethers";
import { getAbi, getCreationBytecode } from "./src/core/contracts";
import { deployPrivateInteropStack } from "./src/helpers/private-interop-deployer";
import {
  buildSendSpec,
  computeFlowId,
  computeSpecHash,
  encodeErc20Data,
  type SendSpec,
} from "./src/helpers/dummy-flow-helpers";
import { encodeNtvAssetId } from "./src/core/data-encoding";

// ──────────────────────────────────────────────────────────────────────────────
// Configuration
// ──────────────────────────────────────────────────────────────────────────────

const L1_CHAIN_ID = 11155111;
const L1_RPC = process.env.SEPOLIA_RPC ?? "https://ethereum-sepolia-rpc.publicnode.com";
const L1_BRIDGEHUB = "0xc4FD2580C3487bba18D63f50301020132342fdbD";

// BYPASS_VERIFICATION=1 deploys the linker with `_bypassMessageVerification = true`,
// so `recordFinalitySignal` skips the call to `IMessageVerification.proveL2MessageInclusionShared`
// and accepts the commit-log payload at face value. The MESSAGE_VERIFICATION address
// is still the real L1MessageRoot (Bridgehub-managed) — no mock contracts are deployed.
//
// Needed because the current zksync-os testnet chains (creator_testnet, zksync_os_testnet)
// don't expose the EraVM-style `zks_getL2ToL1LogProof` RPC, so the real-proof flow
// can't complete there today. Everything else (commitSend logs on each L2, executeFlow
// priority dispatch, settle on each L2 driving real AR/NTV burn+mint) is unchanged.
const BYPASS_VERIFICATION = process.env.BYPASS_VERIFICATION === "1";

interface ChainCfg {
  name: string;
  chainId: number;
  rpcUrl: string;
  diamondProxy: string;
}

const CHAINS: ChainCfg[] = [
  {
    name: "creator_testnet",
    chainId: 278701,
    rpcUrl: process.env.CREATOR_RPC ?? "https://rpc.testnet.oncreator.com",
    diamondProxy: "0xFFb5327A449c1FFDF38b611c96392E58e009c639",
  },
  {
    name: "zksync_os_testnet",
    chainId: 8022833,
    rpcUrl: process.env.ZKOS_RPC ?? "https://zksync-os-testnet-alpha.zksync.dev",
    diamondProxy: "0x02B1ac1Cf0A592aefD3C2246B2431388365dB272",
  },
];

const ETH_PER_L2_DEPOSIT = ethers.utils.parseEther("0.05");
// Direct L2 / L1 txs should land in seconds — if they don't, something is wrong (gas
// underpriced, RPC issue, mempool stuck). Fail fast rather than wait forever. The
// L1->L2 priority-tx flow has its own (much longer) polling loop.
const FAST_TX_TIMEOUT_MS = 60_000;
const TEST_TOKEN_AMOUNT = ethers.utils.parseUnits("100", 18);
const SWAP_AMOUNT = ethers.utils.parseUnits("10", 18);
const FLOW_DEADLINE_SECONDS = 24 * 60 * 60; // 24h - generous; verify-batch wait may take hours
const L2_GAS_LIMIT_PRIORITY = 5_000_000;
const L2_GAS_PER_PUBDATA = 800;
const L1_PRIORITY_GAS_PRICE = ethers.utils.parseUnits("50", "gwei");

// Keep state OUTSIDE outputs/ — the anvil interop suite's cleanup.sh wipes that
// directory wholesale. atomic-interop-state/ is gitignore'd separately. Bypass-mode
// runs persist to a separate file so the real-verifier deployment record stays intact.
const STATE_FILE = path.join(
  __dirname,
  "atomic-interop-state",
  BYPASS_VERIFICATION ? "atomic-interop-testnet-bypass.json" : "atomic-interop-testnet.json"
);

// ──────────────────────────────────────────────────────────────────────────────
// Persisted state
// ──────────────────────────────────────────────────────────────────────────────

interface PerChainState {
  name: string;
  rpcUrl: string;
  diamondProxy: string;
  ethDepositTxHash?: string;
  escrowAddress?: string;
  privateStack?: {
    assetTracker: string;
    ntv: string;
    assetRouter: string;
    interopCenter: string;
    interopHandler: string;
  };
  wired?: boolean;
  testTokenAddress?: string;
  testTokenAssetId?: string;
  commitTxHash?: string;
  commitL2BatchNumber?: number;
  commitL2MessageIndex?: number;
  commitL2TxNumberInBatch?: number;
  commitMerkleProof?: string[];
  commitLogMessage?: { txNumberInBatch: number; sender: string; data: string };
  authorizeTxHashes?: string[];
  settleTxHash?: string;
}

interface State {
  wallet?: string;
  l1: {
    chainId: number;
    bridgehub: string;
    linker?: string;
    bypassVerification?: boolean;
  };
  chains: Record<string, PerChainState>;
  swap?: {
    flowId: string;
    deadline: number;
    sortedChainIds: number[];
    specsBySender: Record<string, SendSpecJSON>;
    registerTxHash?: string;
    recordFinalityTxHash?: string;
    executeFlowTxHash?: string;
  };
}

interface SendSpecJSON {
  destChainId: string;
  recipient: string;
  originChainId: string;
  originToken: string;
  amount: string;
  erc20Data: string;
  depositor: string;
}

function loadState(): State {
  if (!fs.existsSync(STATE_FILE)) {
    return {
      l1: { chainId: L1_CHAIN_ID, bridgehub: L1_BRIDGEHUB, bypassVerification: BYPASS_VERIFICATION },
      chains: {},
    };
  }
  return JSON.parse(fs.readFileSync(STATE_FILE, "utf8")) as State;
}

function saveState(_state: State): void {
  fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
  fs.writeFileSync(STATE_FILE, JSON.stringify(_state, null, 2));
}

function chainState(_state: State, _cfg: ChainCfg): PerChainState {
  const key = String(_cfg.chainId);
  if (!_state.chains[key]) {
    _state.chains[key] = { name: _cfg.name, rpcUrl: _cfg.rpcUrl, diamondProxy: _cfg.diamondProxy };
  }
  return _state.chains[key];
}

// ──────────────────────────────────────────────────────────────────────────────
// Helpers
// ──────────────────────────────────────────────────────────────────────────────

function getPk(): string {
  const pk = process.env.PK;
  if (!pk) throw new Error("Set PK environment variable (use: PK=$(cat ~/.test_pk))");
  return pk.startsWith("0x") ? pk : "0x" + pk;
}

function specToJSON(_s: SendSpec): SendSpecJSON {
  return {
    destChainId: _s.destChainId.toString(),
    recipient: _s.recipient,
    originChainId: _s.originChainId.toString(),
    originToken: _s.originToken,
    amount: _s.amount.toString(),
    erc20Data: _s.erc20Data,
    depositor: _s.depositor,
  };
}

function specFromJSON(_j: SendSpecJSON): SendSpec {
  return {
    destChainId: BigNumber.from(_j.destChainId),
    recipient: _j.recipient,
    originChainId: BigNumber.from(_j.originChainId),
    originToken: _j.originToken,
    amount: BigNumber.from(_j.amount),
    erc20Data: _j.erc20Data,
    depositor: _j.depositor,
  };
}

/**
 * Wait for a tx receipt with a fixed timeout. ethers' default `.wait()` waits forever,
 * which masks problems like underpriced gas. If the tx is genuinely going to land slowly
 * (e.g. an L1->L2 priority tx), poll with a different mechanism instead.
 */
async function waitFast(
  _provider: providers.JsonRpcProvider,
  _txHash: string,
  _label: string,
  _timeoutMs: number = FAST_TX_TIMEOUT_MS
): Promise<ethers.providers.TransactionReceipt> {
  const r = await _provider.waitForTransaction(_txHash, 1, _timeoutMs);
  if (!r) {
    throw new Error(`${_label}: tx ${_txHash} not confirmed within ${_timeoutMs}ms — likely hung (underpriced gas / RPC stuck).`);
  }
  if (r.status === 0) {
    throw new Error(`${_label}: tx ${_txHash} reverted (status 0). Check trace: cast run ${_txHash} -r <rpc>`);
  }
  return r;
}

async function gasOverridesForL2(_provider: providers.JsonRpcProvider) {
  const gp = await _provider.getGasPrice();
  // zksync_os_testnet charges pubdata gas for the deployed bytecode at a rate that
  // varies per chain — empirically ~2000-3000 gas/byte. Need >45M for a 22KB contract.
  // 100M gives headroom for the largest contracts (~45KB).
  return {
    deploy: { gasPrice: gp.mul(2), gasLimit: 100_000_000, type: 0 },
    init: { gasPrice: gp.mul(2), gasLimit: 10_000_000, type: 0 },
  };
}

// ──────────────────────────────────────────────────────────────────────────────
// preflight
// ──────────────────────────────────────────────────────────────────────────────

async function preflight(): Promise<void> {
  const pk = getPk();
  const wallet = new Wallet(pk);
  console.log(`Wallet: ${wallet.address}`);

  const l1Provider = new providers.JsonRpcProvider(L1_RPC);
  const l1Balance = await l1Provider.getBalance(wallet.address);
  console.log(`Sepolia balance: ${ethers.utils.formatEther(l1Balance)} ETH`);
  if (l1Balance.lt(ethers.utils.parseEther("0.5"))) {
    console.error("Insufficient Sepolia ETH — need at least 0.5 ETH.");
    process.exit(1);
  }

  for (const c of CHAINS) {
    const p = new providers.JsonRpcProvider(c.rpcUrl);
    const balance = await p.getBalance(wallet.address);
    const nonce = await p.getTransactionCount(wallet.address);
    const block = await p.getBlockNumber();
    console.log(`${c.name} (chainId ${c.chainId}): nonce=${nonce} balance=${ethers.utils.formatEther(balance)} block=${block}`);
  }

  const state = loadState();
  state.wallet = wallet.address;
  for (const c of CHAINS) chainState(state, c); // populate empty entries
  saveState(state);
  console.log("\nPreflight OK. State saved.");
}

// ──────────────────────────────────────────────────────────────────────────────
// bridge-eth
// ──────────────────────────────────────────────────────────────────────────────

async function bridgeEth(): Promise<void> {
  const pk = getPk();
  const state = loadState();
  const l1Provider = new providers.JsonRpcProvider(L1_RPC);
  const l1Wallet = new Wallet(pk, l1Provider);
  const bridgehub = new Contract(L1_BRIDGEHUB, getAbi("L1Bridgehub"), l1Wallet);

  // Allow targeting a single chain + custom amount (e.g. for one-shot top-ups):
  //   BRIDGE_CHAIN=8022833 BRIDGE_AMOUNT_ETH=0.2 ... bridge-eth
  const targetChainIdEnv = process.env.BRIDGE_CHAIN;
  const amountEnv = process.env.BRIDGE_AMOUNT_ETH;
  const targetChainId = targetChainIdEnv ? Number(targetChainIdEnv) : undefined;
  const depositAmount = amountEnv ? ethers.utils.parseEther(amountEnv) : ETH_PER_L2_DEPOSIT;
  const chainsToProcess = targetChainId ? CHAINS.filter((c) => c.chainId === targetChainId) : CHAINS;
  if (targetChainId && chainsToProcess.length === 0) {
    throw new Error(`BRIDGE_CHAIN=${targetChainId} matches no known chain`);
  }

  for (const c of chainsToProcess) {
    const cs = chainState(state, c);
    const l2Provider = new providers.JsonRpcProvider(c.rpcUrl);
    const balance = await l2Provider.getBalance(l1Wallet.address);
    // For one-shot top-ups (env override provided), force a deposit regardless of
    // current balance — the caller knows what they need.
    const forceDeposit = targetChainId !== undefined;
    if (!forceDeposit && balance.gte(ETH_PER_L2_DEPOSIT)) {
      console.log(`[${c.name}] balance ${ethers.utils.formatEther(balance)} ETH already ≥ ${ethers.utils.formatEther(ETH_PER_L2_DEPOSIT)}, skipping deposit.`);
      continue;
    }

    const baseCost: BigNumber = await bridgehub.l2TransactionBaseCost(
      c.chainId,
      L1_PRIORITY_GAS_PRICE,
      L2_GAS_LIMIT_PRIORITY,
      L2_GAS_PER_PUBDATA
    );
    const mintValue = baseCost.add(depositAmount);

    console.log(`[${c.name}] depositing ${ethers.utils.formatEther(depositAmount)} ETH (mintValue=${ethers.utils.formatEther(mintValue)})...`);
    const tx = await bridgehub.requestL2TransactionDirect(
      {
        chainId: c.chainId,
        mintValue,
        l2Contract: l1Wallet.address,
        l2Value: depositAmount,
        l2Calldata: "0x",
        l2GasLimit: L2_GAS_LIMIT_PRIORITY,
        l2GasPerPubdataByteLimit: L2_GAS_PER_PUBDATA,
        factoryDeps: [],
        refundRecipient: l1Wallet.address,
      },
      { value: mintValue, gasLimit: 1_000_000 }
    );
    await waitFast(l1Provider, tx.hash, `[${c.name}] bridge-eth deposit on L1`);
    // Don't store the tx hash for one-shot top-ups — that slot is for the original
    // first-funding deposit which the rest of the pipeline keys off of.
    if (!forceDeposit) {
      cs.ethDepositTxHash = tx.hash;
      saveState(state);
    }
    const targetBalance = balance.add(depositAmount);
    console.log(`  L1 tx ${tx.hash}; waiting for L2 balance to reach ${ethers.utils.formatEther(targetBalance)} ETH...`);
    await waitForBalance(l2Provider, l1Wallet.address, targetBalance);
  }
  console.log("Bridge-eth done.");
}

async function waitForBalance(_p: providers.JsonRpcProvider, _addr: string, _target: BigNumber): Promise<void> {
  const start = Date.now();
  // No fixed timeout — testnet priority txs can take ≥30 min.
  while (true) {
    const b = await _p.getBalance(_addr);
    if (b.gte(_target)) {
      console.log(`  L2 balance ${ethers.utils.formatEther(b)} ETH (after ${Math.floor((Date.now() - start) / 1000)}s)`);
      return;
    }
    await sleep(15_000);
  }
}

function sleep(_ms: number) {
  return new Promise((r) => setTimeout(r, _ms));
}

// ──────────────────────────────────────────────────────────────────────────────
// deploy-l2
// ──────────────────────────────────────────────────────────────────────────────

async function deployL2(): Promise<void> {
  const pk = getPk();
  const state = loadState();

  // Phase A: deploy L2FlowEscrow on each chain. Escrow addresses no longer need to match
  // across L2s — L1FlowLinker stores per-chain entries via its initialize().
  for (const c of CHAINS) {
    const cs = chainState(state, c);
    if (cs.escrowAddress) {
      console.log(`[${c.name}] escrow already at ${cs.escrowAddress}, skipping.`);
      continue;
    }
    const provider = new providers.JsonRpcProvider(c.rpcUrl);
    const wallet = new Wallet(pk, provider);
    const nonce = await provider.getTransactionCount(wallet.address);
    const gp = await provider.getGasPrice();
    const factory = new ContractFactory(getAbi("L2FlowEscrow"), getCreationBytecode("L2FlowEscrow"), wallet);
    console.log(`[${c.name}] deploying L2FlowEscrow at nonce ${nonce}...`);
    // zksync-os charges gas for pubdata of the deployed bytecode. The per-byte rate
    // varies between chains; use 50M to match the rest of the deploy budgets.
    const escrow = await factory.deploy({ gasPrice: gp.mul(2), gasLimit: 50_000_000, type: 0 });
    await waitFast(provider, escrow.deployTransaction.hash, `[${c.name}] L2FlowEscrow deploy`);
    cs.escrowAddress = escrow.address;
    saveState(state);
    console.log(`  escrow: ${escrow.address}`);
  }

  // Escrows are registered per-chain on L1FlowLinker.initialize, so addresses are
  // allowed to differ across L2s. Just log what we have for visibility.
  for (const c of CHAINS) {
    console.log(`  ${c.name}: escrow = ${state.chains[String(c.chainId)].escrowAddress}`);
  }

  // Phase B: deploy private interop stack on each chain.
  for (const c of CHAINS) {
    const cs = chainState(state, c);
    if (cs.privateStack) {
      console.log(`[${c.name}] private stack already deployed: ${JSON.stringify(cs.privateStack)}; skipping.`);
      continue;
    }
    const provider = new providers.JsonRpcProvider(c.rpcUrl);
    const { deploy, init } = await gasOverridesForL2(provider);
    console.log(`\n[${c.name}] deploying private interop stack...`);
    const result = await deployPrivateInteropStack(
      c.rpcUrl,
      c.chainId,
      L1_CHAIN_ID,
      (line) => console.log(`  ${line}`),
      {
        deployerKey: pk,
        skipFunding: true,
        deployGasOverrides: deploy,
        initGasOverrides: init,
      }
    );
    cs.privateStack = {
      assetTracker: result.assetTracker,
      ntv: result.ntv,
      assetRouter: result.assetRouter,
      interopCenter: result.interopCenter,
      interopHandler: result.interopHandler,
    };
    saveState(state);
  }

  console.log("\nDeploy-l2 done.");
}

// ──────────────────────────────────────────────────────────────────────────────
// wire-l2
// ──────────────────────────────────────────────────────────────────────────────

async function wireL2(): Promise<void> {
  const pk = getPk();
  const state = loadState();

  // Cross-register remote AR addresses. We bypass the shared `registerRemoteRouters`
  // helper because it takes a single gas-override blob — and L2 gas prices vary widely
  // between testnets (zksync_os_testnet is ~6× creator_testnet at time of writing), so
  // using one chain's price for the other leaves the underpriced tx hung in mempool.
  // Per-chain gas price + idempotent skip-if-already-registered keeps this safe to retry.
  for (const c of CHAINS) {
    const cs = chainState(state, c);
    if (!cs.privateStack) continue;
    const provider = new providers.JsonRpcProvider(c.rpcUrl);
    const wallet = new Wallet(pk, provider);
    const gp = await provider.getGasPrice();
    const ar = new Contract(cs.privateStack.assetRouter, getAbi("PrivateL2AssetRouter"), wallet);
    for (const other of CHAINS) {
      if (other.chainId === c.chainId) continue;
      const otherCs = state.chains[String(other.chainId)];
      if (!otherCs?.privateStack) continue;
      const current: string = await ar.remoteRouterAddress(other.chainId);
      if (current !== ethers.constants.AddressZero) {
        console.log(`[${c.name}] remote router for ${other.chainId} already ${current}, skipping.`);
        continue;
      }
      console.log(`[${c.name}] setRemoteRouter(${other.chainId}, ${otherCs.privateStack.assetRouter})...`);
      const tx = await ar.setRemoteRouter(other.chainId, otherCs.privateStack.assetRouter, {
        gasPrice: gp.mul(2),
        gasLimit: 1_000_000,
        type: 0,
      });
      await waitFast(provider, tx.hash, `[${c.name}] setRemoteRouter(${other.chainId})`);
      console.log(`  ${tx.hash}`);
    }
  }

  // For each chain: initialize escrow + setAtomicFlowEscrow on the private AR.
  for (const c of CHAINS) {
    const cs = chainState(state, c);
    if (!cs.escrowAddress || !cs.privateStack) {
      throw new Error(`[${c.name}] missing escrow or private stack; run deploy-l2 first.`);
    }
    if (cs.wired) {
      console.log(`[${c.name}] already wired, skipping.`);
      continue;
    }
    if (!state.l1.linker) {
      throw new Error("L1FlowLinker not yet deployed; run deploy-l1 first.");
    }
    const provider = new providers.JsonRpcProvider(c.rpcUrl);
    const wallet = new Wallet(pk, provider);
    const gp = await provider.getGasPrice();
    const gas = { gasPrice: gp.mul(2), gasLimit: 1_000_000, type: 0 };

    const escrow = new Contract(cs.escrowAddress, getAbi("L2FlowEscrow"), wallet);
    const currentLinker: string = await escrow.L1_LINKER();
    if (currentLinker === ethers.constants.AddressZero) {
      console.log(`[${c.name}] initializing escrow at ${cs.escrowAddress}...`);
      const initTx = await escrow.initialize(state.l1.linker, cs.privateStack.assetRouter, cs.privateStack.ntv, gas);
      await waitFast(provider, initTx.hash, `[${c.name}] escrow.initialize`);
    } else {
      console.log(`[${c.name}] escrow already initialized (linker=${currentLinker}), skipping.`);
    }

    const ar = new Contract(cs.privateStack.assetRouter, getAbi("PrivateL2AssetRouter"), wallet);
    const currentAfe: string = await ar.atomicFlowEscrow();
    if (currentAfe === ethers.constants.AddressZero) {
      console.log(`[${c.name}] setting atomicFlowEscrow on private AR...`);
      const setTx = await ar.setAtomicFlowEscrow(cs.escrowAddress, gas);
      await waitFast(provider, setTx.hash, `[${c.name}] setAtomicFlowEscrow`);
    } else {
      console.log(`[${c.name}] AR.atomicFlowEscrow already set (${currentAfe}), skipping.`);
    }

    cs.wired = true;
    saveState(state);
    console.log(`  wired.`);
  }
  console.log("wire-l2 done.");
}

// ──────────────────────────────────────────────────────────────────────────────
// deploy-l1
// ──────────────────────────────────────────────────────────────────────────────

async function deployL1(): Promise<void> {
  const pk = getPk();
  const state = loadState();
  if (state.l1.linker) {
    console.log(`L1FlowLinker already at ${state.l1.linker}, skipping.`);
    return;
  }
  // Build per-chain (chainId, escrow) list from state. Each chain must have its escrow
  // deployed; the linker stores them in its initialize map.
  const initChainIds: number[] = [];
  const initEscrows: string[] = [];
  for (const c of CHAINS.slice().sort((a, b) => a.chainId - b.chainId)) {
    const cs = state.chains[String(c.chainId)];
    if (!cs?.escrowAddress) throw new Error(`[${c.name}] escrow not deployed yet; run deploy-l2 first.`);
    initChainIds.push(c.chainId);
    initEscrows.push(cs.escrowAddress);
  }

  const l1Provider = new providers.JsonRpcProvider(L1_RPC);
  const wallet = new Wallet(pk, l1Provider);
  console.log(`Deploying L1FlowLinker on Sepolia (bridgehub=${L1_BRIDGEHUB}, bypassVerification=${BYPASS_VERIFICATION})...`);
  const factory = new ContractFactory(getAbi("L1FlowLinker"), getCreationBytecode("L1FlowLinker"), wallet);
  const linker = await factory.deploy(L1_BRIDGEHUB, BYPASS_VERIFICATION);
  await waitFast(l1Provider, linker.deployTransaction.hash, "L1FlowLinker deploy");
  console.log(`  linker: ${linker.address}`);

  console.log(`Initializing linker with per-chain escrows:`);
  for (let i = 0; i < initChainIds.length; i++) console.log(`  chain ${initChainIds[i]} → ${initEscrows[i]}`);
  const initTx = await linker.initialize(initChainIds, initEscrows);
  await waitFast(l1Provider, initTx.hash, "L1FlowLinker.initialize");

  state.l1.linker = linker.address;
  saveState(state);
}

// ──────────────────────────────────────────────────────────────────────────────
// tokens
// ──────────────────────────────────────────────────────────────────────────────

async function deployTokens(): Promise<void> {
  const pk = getPk();
  const state = loadState();
  for (const c of CHAINS) {
    const cs = chainState(state, c);
    if (cs.testTokenAddress && cs.testTokenAssetId) {
      console.log(`[${c.name}] token already at ${cs.testTokenAddress} (assetId ${cs.testTokenAssetId}), skipping.`);
      continue;
    }
    const provider = new providers.JsonRpcProvider(c.rpcUrl);
    const wallet = new Wallet(pk, provider);
    const gp = await provider.getGasPrice();
    // 30M for the deploy: zksync_os charges pubdata at runtime gas rate, so even a 3KB
    // ERC20 needs ~10M+ to cover the pubdata-cost check on top of constructor exec.
    const deployGas = { gasPrice: gp.mul(2), gasLimit: 30_000_000, type: 0 };
    const gas = { gasPrice: gp.mul(2), gasLimit: 2_000_000, type: 0 };

    if (!cs.testTokenAddress) {
      console.log(`[${c.name}] deploying TestnetERC20Token...`);
      const factory = new ContractFactory(getAbi("TestnetERC20Token"), getCreationBytecode("TestnetERC20Token"), wallet);
      const token = await factory.deploy(`AtomicTest-${c.chainId}`, `ATM${c.chainId}`, 18, deployGas);
      await waitFast(provider, token.deployTransaction.hash, `[${c.name}] TestnetERC20Token deploy`);
      cs.testTokenAddress = token.address;
      saveState(state);
      const mintTx = await token.mint(wallet.address, TEST_TOKEN_AMOUNT, gas);
      await waitFast(provider, mintTx.hash, `[${c.name}] token.mint`);
      console.log(`  token=${token.address}, minted ${ethers.utils.formatUnits(TEST_TOKEN_AMOUNT, 18)} ATM${c.chainId} to ${wallet.address}`);
    }

    // Register with the private NTV so the assetId is known.
    if (!cs.privateStack) throw new Error(`[${c.name}] private stack missing; run deploy-l2 first.`);
    const ntv = new Contract(cs.privateStack.ntv, getAbi("PrivateL2NativeTokenVault"), wallet);
    const existingAssetId: string = await ntv.assetId(cs.testTokenAddress!);
    if (existingAssetId === ethers.constants.HashZero) {
      console.log(`[${c.name}] registering token with private NTV...`);
      // registerToken writes asset metadata to the NTV's state and may emit L2->L1 logs
      // that incur pubdata gas. Use the bigger deploy-grade budget on zksync_os.
      const regTx = await ntv.registerToken(cs.testTokenAddress!, deployGas);
      await waitFast(provider, regTx.hash, `[${c.name}] ntv.registerToken`);
    }
    const assetId: string = await ntv.assetId(cs.testTokenAddress!);
    if (assetId === ethers.constants.HashZero) throw new Error(`[${c.name}] NTV failed to assign assetId after registerToken`);
    // Sanity check that the assetId matches the off-chain derivation.
    const expectedAssetId = encodeNtvAssetId(c.chainId, cs.testTokenAddress!);
    if (assetId.toLowerCase() !== expectedAssetId.toLowerCase()) {
      throw new Error(`[${c.name}] assetId mismatch: on-chain ${assetId}, off-chain ${expectedAssetId}`);
    }
    cs.testTokenAssetId = assetId;
    saveState(state);
    console.log(`  assetId=${assetId}`);
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// commit
// ──────────────────────────────────────────────────────────────────────────────

async function commit(): Promise<void> {
  const pk = getPk();
  const state = loadState();
  if (!state.l1.linker) throw new Error("L1FlowLinker not deployed; run deploy-l1 first.");
  for (const c of CHAINS) {
    const cs = chainState(state, c);
    if (!cs.escrowAddress || !cs.privateStack || !cs.testTokenAddress || !cs.testTokenAssetId || !cs.wired) {
      throw new Error(`[${c.name}] not fully wired; run earlier phases.`);
    }
  }

  const wallet = new Wallet(pk);
  const recipient = wallet.address;

  // Build a symmetric A→B / B→A swap: each chain sends SWAP_AMOUNT of its native test
  // token to the wallet's address on the other chain.
  const sortedChainIds = CHAINS.map((c) => c.chainId).slice().sort((a, b) => a - b);
  const specs: SendSpec[] = [];
  const specsBySender: Record<string, SendSpecJSON> = {};
  for (let i = 0; i < CHAINS.length; i++) {
    const src = CHAINS[i];
    const dst = CHAINS[(i + 1) % CHAINS.length];
    const srcState = state.chains[String(src.chainId)];
    const spec = buildSendSpec({
      destChainId: dst.chainId,
      recipient,
      originChainId: src.chainId,
      originToken: srcState.testTokenAddress!,
      amount: SWAP_AMOUNT,
      depositor: recipient,
      erc20Data: encodeErc20Data(src.chainId, `AtomicTest-${src.chainId}`, `ATM${src.chainId}`, 18),
    });
    specs.push(spec);
    specsBySender[String(src.chainId)] = specToJSON(spec);
  }

  let deadline: number;
  let flowId: string;
  if (state.swap?.flowId) {
    flowId = state.swap.flowId;
    deadline = state.swap.deadline;
    console.log(`Resuming swap flowId=${flowId} deadline=${deadline}`);
  } else {
    deadline = Math.floor(Date.now() / 1000) + FLOW_DEADLINE_SECONDS;
    flowId = computeFlowId(specs, sortedChainIds, deadline);
    state.swap = { flowId, deadline, sortedChainIds, specsBySender };
    saveState(state);
    console.log(`flowId=${flowId} deadline=${deadline}`);
  }

  // Register the flow on L1.
  const l1Provider = new providers.JsonRpcProvider(L1_RPC);
  const l1Wallet = new Wallet(pk, l1Provider);
  const linker = new Contract(state.l1.linker!, getAbi("L1FlowLinker"), l1Wallet);
  if (!state.swap.registerTxHash) {
    console.log(`Registering flow on L1...`);
    const tx = await linker.registerFlow(flowId, sortedChainIds, deadline);
    await waitFast(l1Provider, tx.hash, "L1 registerFlow");
    state.swap.registerTxHash = tx.hash;
    saveState(state);
    console.log(`  L1 registerFlow: ${tx.hash}`);
  }

  // For each source chain: approve token to escrow + commitSend.
  for (let i = 0; i < CHAINS.length; i++) {
    const src = CHAINS[i];
    const cs = chainState(state, src);
    if (cs.commitTxHash) {
      console.log(`[${src.name}] already committed via ${cs.commitTxHash}, skipping.`);
      continue;
    }
    const provider = new providers.JsonRpcProvider(src.rpcUrl);
    const wallet2 = new Wallet(pk, provider);
    const gp = await provider.getGasPrice();
    const gas = { gasPrice: gp.mul(2), gasLimit: 3_000_000, type: 0 };

    const token = new Contract(cs.testTokenAddress!, getAbi("TestnetERC20Token"), wallet2);
    const allowance: BigNumber = await token.allowance(wallet2.address, cs.escrowAddress!);
    if (allowance.lt(SWAP_AMOUNT)) {
      console.log(`[${src.name}] approving token to escrow...`);
      const apTx = await token.approve(cs.escrowAddress!, SWAP_AMOUNT, gas);
      await waitFast(provider, apTx.hash, `[${src.name}] token.approve`);
    }

    const escrow = new Contract(cs.escrowAddress!, getAbi("L2FlowEscrow"), wallet2);
    console.log(`[${src.name}] commitSend...`);
    const tx = await escrow.commitSend(flowId, specs[i], gas);
    const receipt = await waitFast(provider, tx.hash, `[${src.name}] commitSend`);
    cs.commitTxHash = tx.hash;
    cs.commitL2BatchNumber = (receipt as ethers.providers.TransactionReceipt & { l1BatchNumber?: number }).l1BatchNumber ?? undefined;
    saveState(state);
    console.log(`  commitSend tx: ${tx.hash}, l1BatchNumber=${cs.commitL2BatchNumber ?? "(not yet sealed)"}`);
  }
  console.log("commit done.");
}

// ──────────────────────────────────────────────────────────────────────────────
// wait-verify : poll until both commit batches are executed on Sepolia
// ──────────────────────────────────────────────────────────────────────────────

async function waitVerify(): Promise<void> {
  const state = loadState();
  for (const c of CHAINS) {
    const cs = chainState(state, c);
    if (!cs.commitTxHash) throw new Error(`[${c.name}] no commit tx; run commit first.`);
    if (cs.commitMerkleProof) {
      console.log(`[${c.name}] proof already fetched, skipping.`);
      continue;
    }
    const l2Provider = new providers.JsonRpcProvider(c.rpcUrl);

    if (BYPASS_VERIFICATION) {
      // Bypass-mode linker accepts any (batch, index, proof) so long as
      // message.sender == escrowOf[chainId] and message.data decodes to the right
      // (tag, flowId, destChainId, specHash). Pull the message bytes from the commit
      // receipt's L1MessageSent event; everything else is stubbed.
      console.log(`[${c.name}] BYPASS_VERIFICATION=1 — pulling L1MessageSent payload from commit receipt (no proof RPC poll).`);
      const receipt = await l2Provider.getTransactionReceipt(cs.commitTxHash!);
      if (!receipt) throw new Error(`[${c.name}] commit tx ${cs.commitTxHash} receipt not found`);
      const msgLog = receipt.logs.find((l) =>
        l.topics[0] === ethers.utils.id("L1MessageSent(address,bytes32,bytes)")
      );
      if (!msgLog) throw new Error(`[${c.name}] no L1MessageSent log in commit tx ${cs.commitTxHash}`);
      const [messageBytes] = ethers.utils.defaultAbiCoder.decode(["bytes"], msgLog.data) as [string];
      cs.commitL2BatchNumber = 0;
      cs.commitL2MessageIndex = 0;
      cs.commitL2TxNumberInBatch = 0;
      cs.commitMerkleProof = [];
      cs.commitLogMessage = {
        txNumberInBatch: 0,
        sender: cs.escrowAddress!,
        data: messageBytes,
      };
      saveState(state);
      console.log(`  payload (${messageBytes.length / 2 - 1} bytes) captured; verification skipped.`);
      continue;
    }

    console.log(`[${c.name}] polling zks_getL2ToL1LogProof for commitSend tx ${cs.commitTxHash}...`);
    const proof = await pollLogProof(l2Provider, cs.commitTxHash!);
    cs.commitL2BatchNumber = proof.l1BatchNumber;
    cs.commitL2MessageIndex = proof.id;
    cs.commitL2TxNumberInBatch = proof.txNumberInBatch;
    cs.commitMerkleProof = proof.proof;
    cs.commitLogMessage = {
      txNumberInBatch: proof.txNumberInBatch,
      sender: cs.escrowAddress!,
      data: proof.message,
    };
    saveState(state);
    console.log(`  batch ${proof.l1BatchNumber}, messageIndex ${proof.id}, proof length ${proof.proof.length}`);
  }
}

interface LogProof {
  id: number;
  proof: string[];
  root: string;
  l1BatchNumber: number;
  txNumberInBatch: number;
  message: string;
}

/** Poll the L2 RPC's zks_getL2ToL1LogProof until non-null. logIndex defaults to 0 (single L2→L1 log per commitSend). */
async function pollLogProof(_p: providers.JsonRpcProvider, _txHash: string): Promise<LogProof> {
  const start = Date.now();
  while (true) {
    // First, ensure we know which logIndex the L1MessageSent log lives at.
    const receipt = await _p.getTransactionReceipt(_txHash);
    if (!receipt) {
      await sleep(15_000);
      continue;
    }
    // zks_getL2ToL1LogProof returns null until the batch is executed on L1.
    // We pass logIndex 0 — commitSend emits exactly one L2->L1 log.
    const raw: unknown = await _p.send("zks_getL2ToL1LogProof", [_txHash, 0]);
    if (raw) {
      const r = raw as {
        id: number;
        proof: string[];
        root: string;
        l1BatchNumber: number;
        l1BatchTxIndex?: number;
        message?: string;
      };
      // Need l1BatchTxIndex from the receipt's l2ToL1Logs entry; fall back to id ordering.
      // Some node implementations include it in the proof response, others don't.
      const l1Receipt = receipt as ethers.providers.TransactionReceipt & {
        l1BatchNumber?: number;
        l2ToL1Logs?: { txIndexInL1Batch?: number; sender?: string; key?: string; value?: string }[];
      };
      const txNumberInBatch = r.l1BatchTxIndex ?? l1Receipt.l2ToL1Logs?.[0]?.txIndexInL1Batch ?? 0;
      // Pull the message body from the receipt's L1MessageSent event.
      const msgLog = receipt.logs.find((l) =>
        l.topics[0] === ethers.utils.id("L1MessageSent(address,bytes32,bytes)")
      );
      if (!msgLog) throw new Error(`No L1MessageSent log in tx ${_txHash}`);
      const decoded = ethers.utils.defaultAbiCoder.decode(["bytes"], msgLog.data);
      return {
        id: r.id,
        proof: r.proof,
        root: r.root,
        l1BatchNumber: r.l1BatchNumber,
        txNumberInBatch,
        message: decoded[0] as string,
      };
    }
    const elapsedMin = Math.floor((Date.now() - start) / 60_000);
    console.log(`  still waiting (${elapsedMin} min elapsed)...`);
    await sleep(60_000);
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// finalize
// ──────────────────────────────────────────────────────────────────────────────

async function finalize(): Promise<void> {
  const pk = getPk();
  const state = loadState();
  if (!state.swap) throw new Error("No swap registered; run commit first.");
  if (state.swap.recordFinalityTxHash) {
    console.log(`Already finalized: ${state.swap.recordFinalityTxHash}`);
    return;
  }
  for (const c of CHAINS) {
    const cs = chainState(state, c);
    if (!cs.commitMerkleProof || !cs.commitLogMessage || cs.commitL2BatchNumber === undefined || cs.commitL2MessageIndex === undefined) {
      throw new Error(`[${c.name}] proof not collected; run wait-verify first.`);
    }
  }
  const l1Provider = new providers.JsonRpcProvider(L1_RPC);
  const l1Wallet = new Wallet(pk, l1Provider);
  const linker = new Contract(state.l1.linker!, getAbi("L1FlowLinker"), l1Wallet);
  const proofs = CHAINS.map((c) => {
    const cs = state.chains[String(c.chainId)];
    return {
      chainId: c.chainId,
      blockOrBatchNumber: cs.commitL2BatchNumber!,
      messageIndex: cs.commitL2MessageIndex!,
      message: cs.commitLogMessage!,
      merkleProof: cs.commitMerkleProof!,
    };
  });
  console.log("recordFinalitySignal on L1...");
  const tx = await linker.recordFinalitySignal(state.swap.flowId, proofs);
  await waitFast(l1Provider, tx.hash, "L1 recordFinalitySignal");
  state.swap.recordFinalityTxHash = tx.hash;
  saveState(state);
  console.log(`  L1 tx: ${tx.hash}`);
}

// ──────────────────────────────────────────────────────────────────────────────
// execute
// ──────────────────────────────────────────────────────────────────────────────

async function executeFlow(): Promise<void> {
  const pk = getPk();
  const state = loadState();
  if (!state.swap?.recordFinalityTxHash) throw new Error("Run finalize first.");
  if (state.swap.executeFlowTxHash) {
    console.log(`Already executed: ${state.swap.executeFlowTxHash}`);
    return;
  }
  const l1Provider = new providers.JsonRpcProvider(L1_RPC);
  const l1Wallet = new Wallet(pk, l1Provider);
  const linker = new Contract(state.l1.linker!, getAbi("L1FlowLinker"), l1Wallet);
  const bridgehub = new Contract(L1_BRIDGEHUB, getAbi("L1Bridgehub"), l1Wallet);

  const chainsAsc = CHAINS.map((c) => c.chainId).slice().sort((a, b) => a - b);
  // Compute mintValue per chain.
  const execParams: { mintValue: BigNumber; l2GasLimit: number; l2GasPerPubdataByteLimit: number; refundRecipient: string }[] = [];
  let total = BigNumber.from(0);
  for (const chainId of chainsAsc) {
    const baseCost: BigNumber = await bridgehub.l2TransactionBaseCost(
      chainId,
      L1_PRIORITY_GAS_PRICE,
      L2_GAS_LIMIT_PRIORITY,
      L2_GAS_PER_PUBDATA
    );
    execParams.push({
      mintValue: baseCost,
      l2GasLimit: L2_GAS_LIMIT_PRIORITY,
      l2GasPerPubdataByteLimit: L2_GAS_PER_PUBDATA,
      refundRecipient: l1Wallet.address,
    });
    total = total.add(baseCost);
  }
  console.log(`executeFlow: sending ${ethers.utils.formatEther(total)} ETH (sum of per-chain mintValues)...`);
  const tx = await linker.executeFlow(state.swap.flowId, execParams, { value: total });
  const receipt = await waitFast(l1Provider, tx.hash, "L1 executeFlow");
  state.swap.executeFlowTxHash = tx.hash;
  saveState(state);
  console.log(`  L1 tx: ${tx.hash}`);
  // Collect canonicalTxHashes from FlowExecuteDispatched events for later wait-l2 polling.
  const dispatchedIface = new ethers.utils.Interface([
    "event FlowExecuteDispatched(bytes32 indexed flowId, uint256 indexed chainId, bytes32 canonicalTxHash)",
  ]);
  for (const log of receipt.logs) {
    if (log.address.toLowerCase() !== state.l1.linker!.toLowerCase()) continue;
    const parsed = (() => {
      // Avoid throwing on unrelated logs.
      const matches = log.topics[0] === dispatchedIface.getEventTopic("FlowExecuteDispatched");
      return matches ? dispatchedIface.parseLog(log) : null;
    })();
    if (!parsed) continue;
    const chainId = (parsed.args.chainId as BigNumber).toNumber();
    const canonicalTxHash = parsed.args.canonicalTxHash as string;
    const cs = state.chains[String(chainId)];
    cs.authorizeTxHashes = (cs.authorizeTxHashes ?? []).concat([canonicalTxHash]);
    console.log(`  chain ${chainId}: canonicalTxHash=${canonicalTxHash}`);
  }
  saveState(state);
}

// ──────────────────────────────────────────────────────────────────────────────
// wait-l2 : poll until each chain's authorize priority tx lands
// ──────────────────────────────────────────────────────────────────────────────

async function waitL2(): Promise<void> {
  const state = loadState();
  for (const c of CHAINS) {
    const cs = chainState(state, c);
    if (!cs.authorizeTxHashes || cs.authorizeTxHashes.length === 0) {
      throw new Error(`[${c.name}] no authorize priority tx hash; run execute first.`);
    }
    const provider = new providers.JsonRpcProvider(c.rpcUrl);
    // Poll the escrow's spec state to know the authorize succeeded — simpler than mapping
    // L1-canonical-tx-hash to its L2-side hash.
    if (!state.swap) throw new Error("No swap state.");
    const specJson = state.swap.specsBySender[String(c.chainId)];
    if (!specJson) {
      console.log(`[${c.name}] no source spec (chain didn't commit anything), checking destination state instead.`);
    }
    const specHash = specJson ? computeSpecHash(specFromJSON(specJson)) : null;
    const escrow = new Contract(cs.escrowAddress!, getAbi("L2FlowEscrow"), provider);
    const start = Date.now();
    if (specHash) {
      console.log(`[${c.name}] waiting for source specHash ${specHash} to become Executable on escrow...`);
      while (true) {
        const stateNum: number = await escrow.bundleState(state.swap.flowId, specHash);
        if (stateNum === 2) {
          // SpecState.Executable
          console.log(`  Executable (after ${Math.floor((Date.now() - start) / 1000)}s)`);
          break;
        }
        await sleep(30_000);
      }
    }
    // Also wait for ANY inbound specs whose destChainId matches this chain.
    for (const [src, specJ] of Object.entries(state.swap.specsBySender)) {
      if (src === String(c.chainId)) continue;
      const s = specFromJSON(specJ);
      if (s.destChainId.toNumber() !== c.chainId) continue;
      const inboundHash = computeSpecHash(s);
      console.log(`[${c.name}] waiting for inbound specHash ${inboundHash} (from chain ${src})...`);
      while (true) {
        const stateNum: number = await escrow.bundleState(state.swap.flowId, inboundHash);
        if (stateNum === 2) {
          console.log(`  inbound Executable`);
          break;
        }
        await sleep(30_000);
      }
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// settle : call execute() on each L2 to perform the burn / mint
// ──────────────────────────────────────────────────────────────────────────────

async function settle(): Promise<void> {
  const pk = getPk();
  const state = loadState();
  if (!state.swap) throw new Error("No swap.");
  for (const c of CHAINS) {
    const cs = chainState(state, c);
    const provider = new providers.JsonRpcProvider(c.rpcUrl);
    const wallet = new Wallet(pk, provider);
    const escrow = new Contract(cs.escrowAddress!, getAbi("L2FlowEscrow"), wallet);
    const gp = await provider.getGasPrice();
    // First-time inbound mint deploys a BridgedStandardERC20 shim via the NTV, which is
    // pubdata-heavy on zksync_os (charges roughly 2k gas per byte of new code). 30M gives
    // headroom for that path; later mints to existing shims will use a small fraction.
    const gas = { gasPrice: gp.mul(2), gasLimit: 30_000_000, type: 0 };

    // SpecState.Executed = 3 (see IDummyFlow.sol). Skip any leg already in that state
    // so the phase can be retried after a partial failure without reverting on the
    // already-settled legs.
    const EXECUTED = 3;

    // Settle this chain's outbound spec (if any).
    const ownSpecJ = state.swap.specsBySender[String(c.chainId)];
    if (ownSpecJ) {
      const s = specFromJSON(ownSpecJ);
      const specHash = computeSpecHash(s);
      const st: number = await escrow.bundleState(state.swap.flowId, specHash);
      if (st === EXECUTED) {
        console.log(`[${c.name}] outbound spec already Executed, skipping.`);
      } else {
        console.log(`[${c.name}] execute() outbound...`);
        const tx = await escrow.execute(state.swap.flowId, s, gas);
        await waitFast(provider, tx.hash, `[${c.name}] execute outbound`);
        cs.settleTxHash = tx.hash;
        saveState(state);
      }
    }
    // Settle inbound specs (destChainId == this chain).
    for (const [src, specJ] of Object.entries(state.swap.specsBySender)) {
      if (src === String(c.chainId)) continue;
      const s = specFromJSON(specJ);
      if (s.destChainId.toNumber() !== c.chainId) continue;
      const specHash = computeSpecHash(s);
      const st: number = await escrow.bundleState(state.swap.flowId, specHash);
      if (st === EXECUTED) {
        console.log(`[${c.name}] inbound from ${src} already Executed, skipping.`);
        continue;
      }
      console.log(`[${c.name}] execute() inbound from ${src}...`);
      const tx = await escrow.execute(state.swap.flowId, s, gas);
      await waitFast(provider, tx.hash, `[${c.name}] execute inbound from ${src}`);
      console.log(`  ${tx.hash}`);
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// verify : check final balances + state
// ──────────────────────────────────────────────────────────────────────────────

async function verify(): Promise<void> {
  const state = loadState();
  if (!state.swap) throw new Error("No swap.");
  for (const c of CHAINS) {
    const cs = chainState(state, c);
    const provider = new providers.JsonRpcProvider(c.rpcUrl);
    // Origin token balance (should have decreased by SWAP_AMOUNT after burn settle).
    const token = new Contract(cs.testTokenAddress!, getAbi("TestnetERC20Token"), provider);
    const ownBalance: BigNumber = await token.balanceOf(state.wallet!);
    console.log(`[${c.name}] origin-token balance: ${ethers.utils.formatUnits(ownBalance, 18)}`);

    // For each inbound spec, query the bridged shim from this chain's NTV.
    for (const [src, specJ] of Object.entries(state.swap.specsBySender)) {
      if (src === String(c.chainId)) continue;
      const s = specFromJSON(specJ);
      if (s.destChainId.toNumber() !== c.chainId) continue;
      const ntv = new Contract(cs.privateStack!.ntv, getAbi("PrivateL2NativeTokenVault"), provider);
      const assetId = encodeNtvAssetId(s.originChainId.toNumber(), s.originToken);
      const shim: string = await ntv.tokenAddress(assetId);
      if (shim === ethers.constants.AddressZero) {
        console.log(`  inbound from ${src}: shim NOT deployed (mint may have failed)`);
        continue;
      }
      const shimToken = new Contract(shim, getAbi("TestnetERC20Token"), provider);
      const bal: BigNumber = await shimToken.balanceOf(state.wallet!);
      console.log(`  bridged shim (${shim}) inbound from ${src}: balance ${ethers.utils.formatUnits(bal, 18)}`);
    }
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// status / reset
// ──────────────────────────────────────────────────────────────────────────────

function status(): void {
  if (!fs.existsSync(STATE_FILE)) {
    console.log("(no state file)");
    return;
  }
  console.log(fs.readFileSync(STATE_FILE, "utf8"));
}

function reset(): void {
  if (fs.existsSync(STATE_FILE)) fs.unlinkSync(STATE_FILE);
  console.log("State cleared.");
}

// ──────────────────────────────────────────────────────────────────────────────
// main
// ──────────────────────────────────────────────────────────────────────────────

async function main() {
  const phase = process.argv[2];
  const phases: Record<string, () => Promise<void> | void> = {
    preflight,
    "bridge-eth": bridgeEth,
    "deploy-l2": deployL2,
    "wire-l2": wireL2,
    "deploy-l1": deployL1,
    tokens: deployTokens,
    commit,
    "wait-verify": waitVerify,
    finalize,
    execute: executeFlow,
    "wait-l2": waitL2,
    settle,
    verify,
    status,
    reset,
  };
  if (!phase || !phases[phase]) {
    console.error(`Usage: PK=... ts-node atomic-interop-testnet.ts <phase>`);
    console.error(`Phases: ${Object.keys(phases).join(", ")}`);
    process.exit(1);
  }
  await phases[phase]();
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
