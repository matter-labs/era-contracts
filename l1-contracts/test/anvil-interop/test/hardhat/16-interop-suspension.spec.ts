import { expect } from "chai";
import { ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { InteropChainRegistrar } from "../../src/deployers/interop-chain-registrar";
import { getAbi } from "../../src/core/contracts";
import { BundleStatus, L2_BRIDGEHUB_ADDR } from "../../src/core/const";
import { createProvider, getInteropChainIds, getL1RpcUrl, getL2RpcUrl } from "../../src/core/utils";
import { encodeEvmChainAddress } from "../../src/helpers/erc7930";
import {
  deployDummyInteropRecipient,
  executeBundle,
  getBundleStatus,
  getInteropProtocolFee,
  sendInteropMessage,
} from "../../src/helpers/interop-helpers";
import type { InteropSendResult } from "../../src/helpers/interop-helpers";
import { executeTokenTransfer, expectTokenTransfer } from "../../src/helpers/token-transfer";
import {
  captureBalance,
  customError,
  expectBalanceDelta,
  expectRevert,
  randomBigNumber,
} from "../../src/helpers/balance-helpers";

const TOKEN_AMOUNT_MIN = ethers.utils.parseUnits("1", 18);
const TOKEN_AMOUNT_MAX = ethers.utils.parseUnits("10", 18);

/**
 * 16 - Interop suspension
 *
 * Governance suspends a chain on L1 with one transaction, and every chain refuses interop to and from it once it reads
 * L1 at a newer anchor; resuming restores the pair, see {protocol-docs/l1sload.md#suspending-a-chain}. The tests run
 * in order: each starts from the state the previous one left.
 *
 * Topology: interopChainIds[1] is suspended; interopChainIds[0] and interopChainIds[1] allow each other.
 */
describe("16 - Interop suspension", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let chainId: number;
  let suspendedChainId: number;
  let registrar: InteropChainRegistrar;
  let sender: ethers.Contract;
  let chainProvider: ethers.providers.JsonRpcProvider;
  let suspendedProvider: ethers.providers.JsonRpcProvider;
  let chainBridgehub: ethers.Contract;
  let recipient: string;
  /** The suspended chain's bundle, sent before the suspension, that the chain executes once it is resumed. */
  let heldMessage: InteropSendResult;

  before(async () => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    const interopChainIds = getInteropChainIds(state.chains.config);
    if (interopChainIds.length < 2) {
      throw new Error("Need at least 2 interop chains for interop suspension tests");
    }
    [chainId, suspendedChainId] = interopChainIds;

    const l1RpcUrl = getL1RpcUrl(state);
    registrar = new InteropChainRegistrar(
      l1RpcUrl,
      state.l1Addresses,
      new Map(interopChainIds.map((id) => [id, getL2RpcUrl(state, id)]))
    );
    sender = new ethers.Contract(
      state.l1Addresses.chainRegistrationSender,
      getAbi("ChainRegistrationSender"),
      createProvider(l1RpcUrl)
    );
    chainProvider = createProvider(getL2RpcUrl(state, chainId));
    suspendedProvider = createProvider(getL2RpcUrl(state, suspendedChainId));
    chainBridgehub = new ethers.Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), chainProvider);
    recipient = await deployDummyInteropRecipient(chainProvider);

    expect(await sender.interopPeerAllowed(chainId, suspendedChainId), "the chain's side").to.be.true;
    expect(await sender.interopPeerAllowed(suspendedChainId, chainId), "the peer's side").to.be.true;
  });

  it("governance suspends a chain, and its peers read the suspension at the next anchor", async () => {
    heldMessage = await sendInteropMessage({
      sourceProvider: suspendedProvider,
      recipient: encodeEvmChainAddress(recipient, chainId),
      payload: "0x",
      attributes: [],
      value: await getInteropProtocolFee(suspendedProvider),
    });

    await registrar.setInteropSuspended(suspendedChainId, true);

    // Suspension touches neither the whitelist nor the snapshot.
    expect(await sender.interopPeerAllowed(chainId, suspendedChainId), "the chain's side").to.be.true;
    expect(await chainBridgehub.isPeerAllowed(suspendedChainId), "the chain's receive filter").to.be.false;
    const [allowed, baseTokenAssetId] = await chainBridgehub.interopSendTarget(suspendedChainId);
    expect(allowed, "sending to the suspended chain").to.be.false;
    expect(baseTokenAssetId).to.equal(await sender.interopBaseTokenAssetId(suspendedChainId));
  });

  it("rejects transfers to the suspended chain", async () => {
    const sourceToken = state.testTokens![chainId];
    const sourceBefore = await captureBalance(chainProvider, sourceToken);

    await expectRevert(
      () =>
        executeTokenTransfer({
          sourceChainId: chainId,
          targetChainId: suspendedChainId,
          amount: "3",
          sourceTokenAddress: sourceToken,
          logger: (line: string) => console.log(`[interop] ${line}`),
        }),
      "transfer to a suspended chain",
      customError("InteropCenter", "DestinationChainNotAllowed(uint256)", [suspendedChainId]),
      chainProvider
    );

    const sourceAfter = await captureBalance(chainProvider, sourceToken);
    expectBalanceDelta(
      sourceBefore.token!,
      sourceAfter.token!,
      ethers.constants.Zero,
      "rejected transfer source token"
    );
  });

  it("stops the suspended chain from sending", async () => {
    await expectRevert(
      async () =>
        sendInteropMessage({
          sourceProvider: suspendedProvider,
          recipient: encodeEvmChainAddress(recipient, chainId),
          payload: "0x",
          attributes: [],
          value: await getInteropProtocolFee(suspendedProvider),
        }),
      "send from a suspended chain",
      customError("InteropCenter", "DestinationChainNotAllowed(uint256)", [chainId]),
      suspendedProvider
    );
  });

  it("holds the bundle the suspended chain sent before the suspension", async () => {
    await expectRevert(
      () => executeBundle(chainProvider, heldMessage, suspendedChainId),
      "execute a bundle from a suspended chain",
      customError("AtomicFlowManager", "ManagerLegSourceChainNotAllowed(uint256)", [suspendedChainId]),
      chainProvider
    );
    expect(await getBundleStatus(chainProvider, heldMessage.bundleHash), "the held bundle's status").to.equal(
      BundleStatus.Unreceived
    );
  });

  it("restores interop once governance resumes the chain", async () => {
    await registrar.setInteropSuspended(suspendedChainId, false);

    expect(await chainBridgehub.isPeerAllowed(suspendedChainId), "the chain's receive filter").to.be.true;
    await expectTokenTransfer({
      sourceChainId: chainId,
      targetChainId: suspendedChainId,
      amount: randomBigNumber(TOKEN_AMOUNT_MIN, TOKEN_AMOUNT_MAX),
      logger: (line: string) => console.log(`[interop] ${line}`),
    });
    await executeBundle(chainProvider, heldMessage, suspendedChainId);
    expect(await getBundleStatus(chainProvider, heldMessage.bundleHash), "the held bundle's status").to.equal(
      BundleStatus.FullyExecuted
    );
  });
});
