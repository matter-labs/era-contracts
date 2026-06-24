/**
 * Real-server atomic swap driver (bundle model), for the zksync-os-integration-tests harness.
 *
 * Unlike the anvil spec (test/hardhat/13-imt-atomic-swap.spec.ts) this runs against TWO REAL
 * L1-settling zksync-os-server chains. The atomic-interop contracts are genesis-deployed at their
 * canonical addresses, so there is no `deployAtomicStack`/`anvil_setCode`. The crucial difference is
 * the per-leg `messageProof`: instead of the mocked `buildSlProofBytes`, we fetch the REAL proof from
 * `zks_getL2ToL1LogProof` for the commitment-tree's `abi.encode(root)` publication — which, for an
 * L1-settled chain, is now a non-final 2-level proof carrying the L1 settlement block (zksync-os-server
 * branch kl/l1-settled-interop-proof). The deadline is therefore set above the actual L1 settlement
 * block (we wait for settlement rather than choosing the block).
 *
 * Usage: ts-node atomic-swap-real.ts <rpcA> <chainIdA> <rpcB> <chainIdB>
 * Exits 0 on success, non-zero on failure (assertion or flow error).
 */
import { BigNumber, Contract, Wallet, ethers, providers } from "ethers";
import { getAbi, getCreationBytecode } from "./src/core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  ATOMIC_SEND_BUNDLE_GAS_LIMIT,
  DEFAULT_TX_GAS_LIMIT,
  INTEROP_CENTER_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_ATOMIC_FLOW_MANAGER_ADDR,
  L2_BRIDGEHUB_ADDR,
  L2_INTEROP_COMMITMENT_TREE_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_INTEROP_ROOT_STORAGE_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
} from "./src/core/const";
import { encodeEvmAddress, encodeEvmChain } from "./src/core/data-encoding";
import {
  atomicBundleAttr,
  getInteropProtocolFee,
  getTokenTransferData,
  indirectCallAttr,
  sendInteropBundle,
} from "./src/helpers/interop-helpers";
import {
  atomicFinalityProofTuple,
  commitValue,
  computeFlowId,
  type IMTLeaf,
  type ImtInclusionProof,
} from "./src/helpers/imt-engine-lib";

const TEST_TOKEN_DECIMALS = 18;
// Mirror of `enum BundleStatus` in contracts/common/Messaging.sol.
const BundleStatus = { Unreceived: 0, Verified: 1, FullyExecuted: 2, Unbundled: 3 } as const;
const LegState = { Unset: 0, Committed: 1, Revertable: 2, Reverted: 3 } as const;

type ChainCtx = {
  chainId: number;
  provider: providers.JsonRpcProvider;
  user: Wallet;
  testToken: Contract;
  interopCenter: Contract;
  interopHandler: Contract;
  manager: Contract;
  tree: Contract;
};

function log(msg: string) {
  // eslint-disable-next-line no-console
  console.log(`[atomic-swap-real] ${msg}`);
}

function assert(cond: boolean, msg: string) {
  if (!cond) throw new Error(`ASSERT FAILED: ${msg}`);
}

/** assetId = keccak256(abi.encode(originChainId, L2_NATIVE_TOKEN_VAULT_ADDR, originToken)). */
function ntvAssetId(originChainId: number, originToken: string): string {
  return ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["uint256", "address", "address"],
      [originChainId, L2_NATIVE_TOKEN_VAULT_ADDR, originToken]
    )
  );
}

/** Deploy a fresh TestnetERC20Token on the chain, mint a large balance to the user, register with the
 *  NTV (so the burn can resolve an assetId), and approve the NTV. */
async function setupToken(ctx: ChainCtx, mintAmount: BigNumber): Promise<void> {
  const factory = new ethers.ContractFactory(
    getAbi("TestnetERC20Token"),
    getCreationBytecode("TestnetERC20Token"),
    ctx.user
  );
  const token = await factory.deploy("AtomicTest", "ATT", TEST_TOKEN_DECIMALS, {
    gasLimit: DEFAULT_TX_GAS_LIMIT,
  });
  await token.deployed();
  ctx.testToken = token.connect(ctx.user);
  await (await ctx.testToken.mint(ctx.user.address, mintAmount)).wait();

  const vault = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), ctx.user);
  const registered: string = await vault.assetId(ctx.testToken.address);
  if (registered === ethers.constants.HashZero) {
    await (await vault.registerToken(ctx.testToken.address)).wait();
  }
  await (await ctx.testToken.approve(L2_NATIVE_TOKEN_VAULT_ADDR, mintAmount)).wait();
  log(`chain ${ctx.chainId}: token ${ctx.testToken.address} deployed/registered/approved`);
}

function bridgeCallStarter(source: ChainCtx, amount: BigNumber, recipient: string) {
  const assetId = ntvAssetId(source.chainId, source.testToken.address);
  return {
    to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
    data: getTokenTransferData(assetId, amount, recipient),
    callAttributes: [indirectCallAttr()],
  };
}

/**
 * Predict a leg's bundleHash via a callStatic on its source chain, targeting `dest`.
 *
 * Unlike the anvil spec (which uses a NON-atomic callStatic), an L1-settling chain rejects non-atomic
 * sends (`NotInGatewayMode`), so we predict with an ATOMIC callStatic carrying a dummy `atomicBundle`
 * attribute. The bundleHash is independent of the atomic params (flowId/deadline/lowNullifierIndex
 * travel out-of-band), so a dummy flowId/deadline is fine; the IMT insert in the callStatic uses
 * lowNullifierIndex 0 (the genesis seed), which is the correct low-leaf for the first insert into the
 * still-fresh tree at prediction time.
 */
async function predictBundleHash(
  source: ChainCtx,
  dest: ChainCtx,
  amount: BigNumber,
  recipient: string,
  fee: BigNumber
): Promise<string> {
  return source.interopCenter.callStatic.sendBundle(
    encodeEvmChain(dest.chainId),
    [bridgeCallStarter(source, amount, recipient)],
    [atomicBundleAttr(ethers.constants.HashZero, 10_000_000, 0)],
    { gasLimit: ATOMIC_SEND_BUNDLE_GAS_LIMIT, value: fee }
  );
}

/** Atomic send of one leg: burn + IMT insert, carrying the atomicBundle attribute. */
async function sendAtomicLeg(params: {
  source: ChainCtx;
  dest: ChainCtx;
  amount: BigNumber;
  recipient: string;
  flowId: string;
  deadline: number;
  predictedBundleHash: string;
  fee: BigNumber;
}): Promise<{ bundleData: string; bundleHash: string; txHash: string }> {
  const { source, dest, amount, recipient, flowId, deadline, predictedBundleHash, fee } = params;
  const value = commitValue(flowId, predictedBundleHash);
  // Low-nullifier (predecessor) index for the about-to-be-inserted leaf, from the server's Rust IMT
  // engine against the current (pre-insert) tree state.
  const latestBlock = await source.provider.getBlockNumber();
  const lowNull: number | null = await source.provider.send("zks_getImtLowNullifierIndex", [value, latestBlock]);
  if (lowNull == null) {
    throw new Error(`no low-nullifier leaf for value ${value} on chain ${source.chainId}`);
  }
  const res = await sendInteropBundle({
    sourceProvider: source.provider,
    destinationChainId: dest.chainId,
    callStarters: [bridgeCallStarter(source, amount, recipient)],
    bundleAttributes: [atomicBundleAttr(flowId, deadline, lowNull)],
    value: fee,
    gasLimit: ATOMIC_SEND_BUNDLE_GAS_LIMIT,
  });
  assert(
    res.bundleHash.toLowerCase() === predictedBundleHash.toLowerCase(),
    `predicted bundleHash ${predictedBundleHash} == emitted ${res.bundleHash}`
  );
  return { bundleData: res.bundleData, bundleHash: res.bundleHash, txHash: res.txHash };
}

/** Find the L2->L1 message index (within the tx) emitted by the commitment tree (sender 0x10012). */
async function commitmentTreeMessageIndex(
  provider: providers.JsonRpcProvider,
  txHash: string
): Promise<number> {
  // zksync receipts carry l2ToL1Logs; the commitment tree's sendToL1 shows up as a log with
  // sender == L2_INTEROP_COMMITMENT_TREE_ADDR. Its position among messenger messages is the index.
  const receipt: any = await provider.send("eth_getTransactionReceipt", [txHash]);
  const logs: any[] = receipt.l2ToL1Logs || [];
  let msgIdx = 0;
  for (const l of logs) {
    const sender: string = (l.sender || "").toLowerCase();
    if (sender === L2_INTEROP_COMMITMENT_TREE_ADDR.toLowerCase()) return msgIdx;
    msgIdx++;
  }
  // Fallback: assume single message.
  return 0;
}

type RawLogProof = {
  batchNumber?: number;
  batch_number?: number;
  id: number;
  proof: string[];
  root: string;
  gatewayBlockNumber: number | null;
};

/** Poll zks_getL2ToL1LogProof (messageRoot) for the commitment-tree publish in `txHash`. */
async function waitForMessageProof(
  provider: providers.JsonRpcProvider,
  txHash: string,
  msgIndex: number,
  timeoutMs = 300_000
): Promise<RawLogProof> {
  const start = Date.now();
  for (;;) {
    const res: RawLogProof | null = await provider.send("zks_getL2ToL1LogProof", [
      txHash,
      msgIndex,
      "messageRoot",
    ]);
    if (res) return res;
    if (Date.now() - start > timeoutMs) throw new Error(`timed out waiting for message proof of ${txHash}`);
    await new Promise((r) => setTimeout(r, 1000));
  }
}

type RpcImtProof = {
  chainImtRoot: string;
  leaf: IMTLeaf;
  imtLeafIndex: number;
  imtProof: string[];
};

/**
 * Build an inclusion proof: the IMT half (root/leaf/index/path) comes from the server's
 * `zks_getImtInclusionProof` (the Rust IMT engine), the message half from the REAL messageProof.
 *
 * The IMT proof is anchored to the atomic-send tx's block — the block whose commitment-tree root
 * the messageProof authenticates.
 */
async function buildRealInclusionProof(params: {
  source: ChainCtx;
  value: string;
  txHash: string;
  rawProof: RawLogProof;
  messageTxNumberInBatch: number;
}): Promise<ImtInclusionProof> {
  const { source, value, txHash, rawProof, messageTxNumberInBatch } = params;
  const sendReceipt: any = await source.provider.send("eth_getTransactionReceipt", [txHash]);
  const sendBlock = BigNumber.from(sendReceipt.blockNumber).toNumber();
  const imt: RpcImtProof | null = await source.provider.send("zks_getImtInclusionProof", [value, sendBlock]);
  if (imt == null) {
    throw new Error(`commit value not present in chain ${source.chainId} IMT (server proof returned null)`);
  }
  const onChainRoot: string = await source.tree.root();
  assert(
    imt.chainImtRoot.toLowerCase() === onChainRoot.toLowerCase(),
    `server IMT root == on-chain root on ${source.chainId}`
  );
  const batchNumber = (rawProof.batchNumber ?? rawProof.batch_number ?? 0).toString();
  return {
    sourceChainId: BigNumber.from(source.chainId).toString(),
    chainImtRoot: imt.chainImtRoot,
    leaf: imt.leaf,
    imtLeafIndex: imt.imtLeafIndex,
    imtProof: imt.imtProof,
    batchNumber,
    messageIndex: rawProof.id.toString(),
    messageTxNumberInBatch,
    messageProof: rawProof.proof,
  };
}

/**
 * Register the two chains with each other for interop, so each chain's L2 Bridgehub knows the other's
 * base-token assetId (`InteropCenter.sendBundle` needs it). The default ecosystem does no interop
 * registration for L1-settling chains, so we trigger it: query the L1 Bridgehub for its
 * `chainRegistrationSender`, then call the permissionless `registerChain(toRegister, registeredOn)`
 * for both directions. Each call sends an L2 service tx that sets `baseTokenAssetId[toRegister]` on
 * `registeredOn`'s L2 Bridgehub; we poll until both are set.
 */
async function registerChainsForInterop(
  l1Rpc: string,
  bridgehubAddr: string,
  chainA: ChainCtx,
  chainB: ChainCtx
): Promise<void> {
  const l1Provider = new providers.JsonRpcProvider(l1Rpc);
  // Standard anvil acct #0 is funded on the L1 anvil; registerChain is permissionless.
  const l1Wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
  const l1Bridgehub = new Contract(bridgehubAddr, getAbi("L1Bridgehub"), l1Wallet);
  const senderAddr: string = await l1Bridgehub.chainRegistrationSender();
  const sender = new Contract(senderAddr, getAbi("ChainRegistrationSender"), l1Wallet);
  log(`chainRegistrationSender = ${senderAddr}`);

  // registerChain(toRegister, registeredOn): A must learn B (-> registerChain(B, A)) and vice versa.
  const directions = [
    { toRegister: chainB, registeredOn: chainA },
    { toRegister: chainA, registeredOn: chainB },
  ];
  for (const { toRegister, registeredOn } of directions) {
    const l2bh = new Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), registeredOn.provider);
    const existing: string = await l2bh.baseTokenAssetId(toRegister.chainId);
    if (existing !== ethers.constants.HashZero) {
      log(`chain ${registeredOn.chainId} already knows ${toRegister.chainId}`);
      continue;
    }
    await (
      await sender.registerChain(toRegister.chainId, registeredOn.chainId, { gasLimit: DEFAULT_TX_GAS_LIMIT })
    ).wait();
    log(`registerChain(${toRegister.chainId} on ${registeredOn.chainId}) submitted; waiting for L2 service tx...`);
    const start = Date.now();
    for (;;) {
      const got: string = await l2bh.baseTokenAssetId(toRegister.chainId);
      if (got !== ethers.constants.HashZero) break;
      if (Date.now() - start > 120_000) {
        throw new Error(`chain ${registeredOn.chainId} never learned ${toRegister.chainId}'s base token`);
      }
      await new Promise((r) => setTimeout(r, 1000));
    }
    log(`chain ${registeredOn.chainId} now knows ${toRegister.chainId}`);
  }
}

/** Poll a chain's L2InteropRootStorage until it has imported the interop root for (l1ChainId, slBlock). */
async function waitForInteropRoot(
  ctx: ChainCtx,
  l1ChainId: number,
  slBlock: number,
  timeoutMs = 180_000
): Promise<void> {
  const storage = new Contract(L2_INTEROP_ROOT_STORAGE_ADDR, getAbi("L2InteropRootStorage"), ctx.provider);
  const start = Date.now();
  for (;;) {
    const root: string = await storage.interopRoots(l1ChainId, slBlock);
    if (root && root !== ethers.constants.HashZero) return;
    if (Date.now() - start > timeoutMs) {
      throw new Error(`chain ${ctx.chainId} never imported interop root (L1 ${l1ChainId}, block ${slBlock})`);
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
}

async function main() {
  const [rpcA, idAStr, rpcB, idBStr, pkArg, l1Rpc, bridgehubAddr] = process.argv.slice(2);
  if (!rpcA || !idAStr || !rpcB || !idBStr || !l1Rpc || !bridgehubAddr) {
    throw new Error(
      "usage: atomic-swap-real.ts <rpcA> <chainIdA> <rpcB> <chainIdB> <depositorPrivateKey> <l1Rpc> <bridgehubAddr>"
    );
  }
  // The depositor/recipient key. Defaults to the standard anvil acct #0, but the integration-test
  // harness funds its own wallet set, so it passes a known-funded key explicitly.
  const userKey = pkArg || ANVIL_DEFAULT_PRIVATE_KEY;
  // sendInteropBundle() signs with getInteropSourcePrivateKey(), which honors ANVIL_INTEROP_PRIVATE_KEY.
  // Point it at our funded depositor so the atomic send is signed by the account that holds the tokens.
  process.env.ANVIL_INTEROP_PRIVATE_KEY = userKey;
  const mkCtx = (rpc: string, chainId: number): ChainCtx => {
    const provider = new providers.JsonRpcProvider(rpc);
    const user = new Wallet(userKey, provider);
    return {
      chainId,
      provider,
      user,
      testToken: undefined as unknown as Contract,
      interopCenter: new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), user),
      interopHandler: new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("InteropHandler"), user),
      manager: new Contract(L2_ATOMIC_FLOW_MANAGER_ADDR, getAbi("AtomicFlowManager"), user),
      tree: new Contract(L2_INTEROP_COMMITMENT_TREE_ADDR, getAbi("L2InteropCommitmentTree"), user),
    };
  };
  const chainA = mkCtx(rpcA, Number(idAStr));
  const chainB = mkCtx(rpcB, Number(idBStr));
  const user = chainA.user.address;

  const aAmount = ethers.utils.parseUnits("10", TEST_TOKEN_DECIMALS);
  const bAmount = ethers.utils.parseUnits("7", TEST_TOKEN_DECIMALS);
  const mint = ethers.utils.parseUnits("1000000", TEST_TOKEN_DECIMALS);

  // generate-l1-state pre-queues an L1->L2 deposit for the test account; the server processes it as it
  // spins up, so wait for the base-token balance before deploying (deploy needs gas).
  for (const ctx of [chainA, chainB]) {
    const start = Date.now();
    for (;;) {
      const bal = await ctx.provider.getBalance(user);
      if (!bal.isZero()) break;
      if (Date.now() - start > 120_000) throw new Error(`account ${user} never funded on chain ${ctx.chainId}`);
      await new Promise((r) => setTimeout(r, 1000));
    }
  }

  log(`setting up tokens on chains ${chainA.chainId} / ${chainB.chainId}`);
  await setupToken(chainA, mint);
  await setupToken(chainB, mint);

  const fee = await getInteropProtocolFee(chainA.provider);

  // Register the chains with each other for interop (sets baseTokenAssetId cross-chain) before any send.
  log("registering chains for interop...");
  await registerChainsForInterop(l1Rpc, bridgehubAddr, chainA, chainB);

  // Deadline is an L1 (settlement-layer) block number; pick well above the current L1 head so the
  // legs' actual settlement blocks land before it. The harness L1 is a fast anvil.
  const deadline = 10_000_000;

  // ── Predict bundleHashes -> flowId ──────────────────────────────────────────────────────────
  const hAB = await predictBundleHash(chainA, chainB, aAmount, user, fee);
  const hBA = await predictBundleHash(chainB, chainA, bAmount, user, fee);
  const legHashesAsc = BigNumber.from(hAB).lt(BigNumber.from(hBA)) ? [hAB, hBA] : [hBA, hAB];
  const chainIdsAsc = [chainA.chainId, chainB.chainId].sort((x, y) => x - y);
  const flowId = computeFlowId(legHashesAsc, chainIdsAsc, deadline);
  log(`flowId=${flowId} deadline=${deadline}`);

  // ── PHASE 1: atomic send each leg ────────────────────────────────────────────────────────────
  const aBefore: BigNumber = await chainA.testToken.balanceOf(user);
  const bBefore: BigNumber = await chainB.testToken.balanceOf(user);
  const ab = await sendAtomicLeg({ source: chainA, dest: chainB, amount: aAmount, recipient: user, flowId, deadline, predictedBundleHash: hAB, fee });
  const ba = await sendAtomicLeg({ source: chainB, dest: chainA, amount: bAmount, recipient: user, flowId, deadline, predictedBundleHash: hBA, fee });
  assert((await chainA.manager.legState(flowId, hAB)) === LegState.Committed, "AB committed on A");
  assert((await chainB.manager.legState(flowId, hBA)) === LegState.Committed, "BA committed on B");
  assert((await chainA.testToken.balanceOf(user)).eq(aBefore.sub(aAmount)), "A burned aAmount");
  assert((await chainB.testToken.balanceOf(user)).eq(bBefore.sub(bAmount)), "B burned bAmount");
  log("PHASE 1 ok: both legs committed (burn + IMT insert)");

  // ── PHASE 2: wait for L1 settlement, fetch real message proofs, build inclusion proofs ───────
  const abMsgIdx = await commitmentTreeMessageIndex(chainA.provider, ab.txHash);
  const baMsgIdx = await commitmentTreeMessageIndex(chainB.provider, ba.txHash);
  log("waiting for commitment-tree roots to settle on L1...");
  const abRaw = await waitForMessageProof(chainA.provider, ab.txHash, abMsgIdx);
  const baRaw = await waitForMessageProof(chainB.provider, ba.txHash, baMsgIdx);
  log(`AB proof: batch=${abRaw.batchNumber ?? abRaw.batch_number} slBlock=${abRaw.gatewayBlockNumber}`);
  log(`BA proof: batch=${baRaw.batchNumber ?? baRaw.batch_number} slBlock=${baRaw.gatewayBlockNumber}`);

  const abValue = commitValue(flowId, hAB);
  const baValue = commitValue(flowId, hBA);
  const abProof = await buildRealInclusionProof({ source: chainA, value: abValue, txHash: ab.txHash, rawProof: abRaw, messageTxNumberInBatch: 0 });
  const baProof = await buildRealInclusionProof({ source: chainB, value: baValue, txHash: ba.txHash, rawProof: baRaw, messageTxNumberInBatch: 0 });
  const proofsAsc = BigNumber.from(hAB).lt(BigNumber.from(hBA)) ? [abProof, baProof] : [baProof, abProof];
  const finality = atomicFinalityProofTuple({ flowId, deadline, legBundleHashes: legHashesAsc, chainIds: chainIdsAsc, proofs: proofsAsc });

  // Both executeAtomicBundle calls verify EVERY leg, so each executing chain must have imported the
  // L1 interop root at each leg's settlement block before we execute.
  const l1ChainId = (await new providers.JsonRpcProvider(l1Rpc).getNetwork()).chainId;
  const slBlocks = [abRaw.gatewayBlockNumber, baRaw.gatewayBlockNumber].filter(
    (b): b is number => b != null
  );
  log(`waiting for interop roots (L1 ${l1ChainId}) at blocks [${slBlocks.join(", ")}] on both chains...`);
  for (const ctx of [chainA, chainB]) {
    for (const slBlock of slBlocks) {
      await waitForInteropRoot(ctx, l1ChainId, slBlock);
    }
  }
  log("interop roots imported on both chains");

  // ── PHASE 3: executeAtomicBundle on each destination ─────────────────────────────────────────
  log("executing AB on B and BA on A...");
  await (await chainB.interopHandler.executeAtomicBundle(ab.bundleData, finality, { gasLimit: DEFAULT_TX_GAS_LIMIT })).wait();
  await (await chainA.interopHandler.executeAtomicBundle(ba.bundleData, finality, { gasLimit: DEFAULT_TX_GAS_LIMIT })).wait();
  assert((await chainB.interopHandler.bundleStatus(hAB)) === BundleStatus.FullyExecuted, "AB executed on B");
  assert((await chainA.interopHandler.bundleStatus(hBA)) === BundleStatus.FullyExecuted, "BA executed on A");

  // ── Destination mint assertions ──────────────────────────────────────────────────────────────
  const ntvAbi = ["function tokenAddress(bytes32 assetId) view returns (address)"];
  const balAbi = ["function balanceOf(address) view returns (uint256)"];
  const shimAonB = await new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, ntvAbi, chainB.provider).tokenAddress(ntvAssetId(chainA.chainId, chainA.testToken.address));
  assert(shimAonB !== ethers.constants.AddressZero, "shim for A's token on B");
  const shimAonBBal = await new Contract(shimAonB, balAbi, chainB.provider).balanceOf(user);
  assert(shimAonBBal.eq(aAmount), `recipient on B got aAmount (${shimAonBBal} == ${aAmount})`);
  const shimBonA = await new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, ntvAbi, chainA.provider).tokenAddress(ntvAssetId(chainB.chainId, chainB.testToken.address));
  assert(shimBonA !== ethers.constants.AddressZero, "shim for B's token on A");
  const shimBonABal = await new Contract(shimBonA, balAbi, chainA.provider).balanceOf(user);
  assert(shimBonABal.eq(bAmount), `recipient on A got bAmount (${shimBonABal} == ${bAmount})`);

  log("SUCCESS: atomic swap completed end-to-end on two L1-settling chains");
}

main().then(
  () => process.exit(0),
  (e) => {
    // eslint-disable-next-line no-console
    console.error(`[atomic-swap-real] FAILED: ${e?.stack || e}`);
    process.exit(1);
  }
);
