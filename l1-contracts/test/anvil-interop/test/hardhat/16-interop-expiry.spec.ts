import { expect } from "chai";
import { BigNumber, Contract, Wallet, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { InteropChainRegistrar } from "../../src/deployers/interop-chain-registrar";
import { getAbi } from "../../src/core/contracts";
import { getInteropSourcePrivateKey, getInteropUnbundlerPrivateKey } from "../../src/core/accounts";
import {
  BundleStatus,
  ChainFeature,
  DEFAULT_TX_GAS_LIMIT,
  INTEROP_CENTER_ADDR,
  L2_ATOMIC_FLOW_MANAGER_ADDR,
  L2_INTEROP_COMMITMENT_TREE_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_INTEROP_ROOT_STORAGE_ADDR,
  LegState,
} from "../../src/core/const";
import {
  createProvider,
  getChainDiamondProxy,
  getInteropChainIds,
  getL1RpcUrl,
  getL2RpcUrl,
} from "../../src/core/utils";
import { encodeEvmAddress, encodeEvmChain } from "../../src/core/data-encoding";
import {
  captureBalance,
  customError,
  expectBalanceDelta,
  expectEvent,
  expectNativeSpend,
  expectRevert,
} from "../../src/helpers/balance-helpers";
import {
  atomicBundleAttr,
  ensureSettlementInteropRoot,
  executeBundle,
  getBundleStatus,
  getInteropExecutionData,
  getInteropProtocolFee,
  interopBundleSaltAttr,
  interopCallValueAttr,
  sendInteropBundle,
  staticPreviewHash,
} from "../../src/helpers/interop-helpers";
import type { InteropSendResult } from "../../src/helpers/interop-helpers";
import {
  ATOMIC_FLOW_EXPIRABLE_PREIMAGE_VERSION,
  ATOMIC_FLOW_EXPIRY_DELAY,
  DEFAULT_SL_CHAIN_ID,
  atomicFlowTuple,
  buildInclusionProof,
  commitValue,
  commitmentTree,
  computeFlowId,
  expiryValue,
  lowNullifierIndexFor,
  proofTuple,
  reconstructChainImt,
} from "../../src/helpers/imt-engine-lib";
import type { AtomicFlowPreimage } from "../../src/helpers/imt-engine-lib";

const TRANSFER_AMOUNT = ethers.utils.parseEther("0.01");

/**
 * 16 - Expiry of single-leg flows
 *
 * An expirable transfer of base token to an EOA can't execute on its destination, since an EOA has no
 * `receiveMessage`. Once its deadline plus the delay has passed, the destination expires it and the source refunds
 * the sender, see {protocol-docs/atomicity/expiry.md}. The tests run in order: each starts from the state the
 * previous one left.
 *
 * Topology: interopChainIds[0] sends to interopChainIds[1]. The relayer, a different account than the sender, makes
 * the permissionless calls, so the sender's balance moves only by the transfer and its refund.
 */
describe("16 - Expiry of single-leg flows", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let sourceChainId: number;
  let destChainId: number;
  let sourceProvider: ethers.providers.JsonRpcProvider;
  let destProvider: ethers.providers.JsonRpcProvider;
  let registrar: InteropChainRegistrar;
  let sourceManager: Contract;
  let destHandler: Contract;
  let fee: BigNumber;
  /** After every root either chain has imported, so the source accepts the send. */
  let deadline: number;
  const recipient = Wallet.createRandom().address;
  let transfer: InteropSendResult;

  before(async () => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    const interopChainIds = getInteropChainIds(state.chains.config);
    if (interopChainIds.length < 2) {
      throw new Error("Need at least 2 interop chains for expiry tests");
    }
    [sourceChainId, destChainId] = interopChainIds;

    registrar = new InteropChainRegistrar(getL1RpcUrl(state), state.l1Addresses);
    sourceProvider = createProvider(getL2RpcUrl(state, sourceChainId));
    destProvider = createProvider(getL2RpcUrl(state, destChainId));
    sourceManager = new Contract(
      L2_ATOMIC_FLOW_MANAGER_ADDR,
      getAbi("AtomicFlowManager"),
      new Wallet(getInteropUnbundlerPrivateKey(), sourceProvider)
    );
    destHandler = new Contract(
      L2_INTEROP_HANDLER_ADDR,
      getAbi("L2InteropHandler"),
      new Wallet(getInteropUnbundlerPrivateKey(), destProvider)
    );
    fee = await getInteropProtocolFee(sourceProvider);

    const latestRootTimestamps: BigNumber[] = await Promise.all(
      [sourceProvider, destProvider].map((provider) =>
        new Contract(L2_INTEROP_ROOT_STORAGE_ADDR, getAbi("L2InteropRootStorage"), provider).latestInteropRootTimestamp(
          DEFAULT_SL_CHAIN_ID
        )
      )
    );
    deadline = Math.max(...latestRootTimestamps.map((timestamp) => timestamp.toNumber())) + 1;
  });

  /** Sends `TRANSFER_AMOUNT` of base token from the source to `recipient` as an expirable single-leg flow. */
  async function sendExpirableTransfer(): Promise<InteropSendResult> {
    const sender = new Wallet(getInteropSourcePrivateKey(), sourceProvider);
    const salt = ethers.utils.hexlify(ethers.utils.randomBytes(32));
    const callStarters = [
      { to: encodeEvmAddress(recipient), data: "0x", callAttributes: [interopCallValueAttr(TRANSFER_AMOUNT)] },
    ];
    const bundleHash = await staticPreviewHash(
      new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), sender),
      sourceProvider,
      sender.address,
      "previewBundleHash",
      [encodeEvmChain(destChainId), callStarters, [interopBundleSaltAttr(salt)]]
    );
    const preimage: AtomicFlowPreimage = {
      version: ATOMIC_FLOW_EXPIRABLE_PREIMAGE_VERSION,
      deadline,
      settlementLayerChainId: DEFAULT_SL_CHAIN_ID,
      legBundleHashes: [bundleHash],
      legSourceChainIds: [sourceChainId],
    };
    const lowNullifierIndex = await lowNullifierIndexFor(
      commitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR, sourceProvider),
      commitValue(computeFlowId(preimage), bundleHash)
    );
    return sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters,
      bundleAttributes: [atomicBundleAttr(preimage, lowNullifierIndex), interopBundleSaltAttr(salt)],
      value: fee.add(TRANSFER_AMOUNT),
    });
  }

  /** Expires `transfer` on the destination from the relayer. */
  async function expireTransfer(): Promise<ethers.providers.TransactionReceipt> {
    const { bundleData, proof } = await getInteropExecutionData(destProvider, transfer, sourceChainId);
    const lowNullifierIndex = await lowNullifierIndexFor(
      commitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR, destProvider),
      expiryValue(transfer.flowId, transfer.bundleHash)
    );
    return (
      await destHandler.expireAtomicBundle(bundleData, proof, lowNullifierIndex, { gasLimit: DEFAULT_TX_GAS_LIMIT })
    ).wait();
  }

  it("rejects an expirable transfer while the source chain hasn't enabled the feature", async () => {
    await expectRevert(
      () => sendExpirableTransfer(),
      "expirable transfer without the feature",
      customError("AtomicFlowManager", "ManagerExpirableTransfersNotEnabled()", []),
      sourceProvider
    );
  });

  it("enables the feature for the source chain through L1", async () => {
    await registrar.enableChainFeature(
      sourceChainId,
      ChainFeature.ExpirableTransfers,
      getChainDiamondProxy(state.chainAddresses!, sourceChainId),
      sourceProvider
    );
  });

  it("sends an expirable transfer to an EOA, which can't execute on the destination", async () => {
    const before = await captureBalance(sourceProvider);
    transfer = await sendExpirableTransfer();
    const after = await captureBalance(sourceProvider);
    expectNativeSpend(before, after, fee.add(TRANSFER_AMOUNT), transfer.receipt, "expirable transfer");

    const committed = expectEvent(
      transfer.receipt,
      "AtomicFlowManager",
      L2_ATOMIC_FLOW_MANAGER_ADDR,
      "ExpirableFlowCommitted"
    );
    expect(committed.flowId, "committed flow").to.equal(transfer.flowId);
    expect(await sourceManager.legState(transfer.flowId, transfer.bundleHash)).to.equal(LegState.Committed);

    // An EOA has no `receiveMessage`, so the call reverts ("call to non-contract address") without revert data,
    // which Anvil's eth_call doesn't surface. The next test expires the leg with the same finality proof, so this
    // rejection isn't a proof or receive-filter failure.
    const executed = await executeBundle(destProvider, transfer, sourceChainId).then(
      () => true,
      () => false
    );
    expect(executed, "a value call to an EOA executes").to.be.false;
    expect((await destProvider.getBalance(recipient)).isZero(), "the EOA received nothing").to.be.true;
    expect(await getBundleStatus(destProvider, transfer.bundleHash)).to.equal(BundleStatus.Unreceived);
  });

  it("expires the transfer on the destination, after which it can't execute", async () => {
    // Keyed by its own timestamp, so the settlement block is unique to this run.
    const expiryRootTimestamp = deadline + ATOMIC_FLOW_EXPIRY_DELAY + 1;
    await ensureSettlementInteropRoot(destProvider, expiryRootTimestamp, expiryRootTimestamp);

    const receipt = await expireTransfer();
    expect(expectEvent(receipt, "L2InteropHandler", L2_INTEROP_HANDLER_ADDR, "BundleExpired").bundleHash).to.equal(
      transfer.bundleHash
    );
    expect(await getBundleStatus(destProvider, transfer.bundleHash)).to.equal(BundleStatus.Expired);
    const destImt = await reconstructChainImt(commitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR, destProvider));
    const expiry = expiryValue(transfer.flowId, transfer.bundleHash);
    expect(
      destImt.leaves.some((leaf) => BigNumber.from(leaf.value).eq(expiry)),
      "the expiry value is in the destination's IMT"
    ).to.be.true;

    await expectRevert(
      () => executeBundle(destProvider, transfer, sourceChainId),
      "execute an expired transfer",
      customError("L2InteropHandler", "BundleAlreadyProcessed(bytes32)", [transfer.bundleHash]),
      destProvider
    );
  });

  it("refunds the sender on the source against the destination's expiry", async () => {
    const expiryProof = await buildInclusionProof({
      l2Tree: commitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR, destProvider),
      chainId: destChainId,
      value: expiryValue(transfer.flowId, transfer.bundleHash),
      l1Timestamp: deadline + ATOMIC_FLOW_EXPIRY_DELAY + 1,
    });
    const flow = atomicFlowTuple({ flowId: transfer.flowId, preimage: transfer.preimage });
    const sender = new Wallet(getInteropSourcePrivateKey(), sourceProvider).address;
    const senderBefore = await sourceProvider.getBalance(sender);

    await (
      await sourceManager.authorizeExpiryRefund(flow, transfer.bundleData, proofTuple(expiryProof), {
        gasLimit: DEFAULT_TX_GAS_LIMIT,
      })
    ).wait();
    expect(await sourceManager.legState(transfer.flowId, transfer.bundleHash)).to.equal(LegState.Revertable);

    await (
      await sourceManager.claimRefund(transfer.flowId, transfer.bundleData, { gasLimit: DEFAULT_TX_GAS_LIMIT })
    ).wait();
    expect(await sourceManager.legState(transfer.flowId, transfer.bundleHash)).to.equal(LegState.Reverted);
    expectBalanceDelta(senderBefore, await sourceProvider.getBalance(sender), TRANSFER_AMOUNT, "refund to the sender");
  });
});
