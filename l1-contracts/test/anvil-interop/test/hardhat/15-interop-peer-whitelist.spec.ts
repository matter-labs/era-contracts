import { expect } from "chai";
import { ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { InteropChainRegistrar } from "../../src/deployers/interop-chain-registrar";
import { getAbi } from "../../src/core/contracts";
import { L2_BRIDGEHUB_ADDR } from "../../src/core/const";
import { getInteropSourceAddress } from "../../src/core/accounts";
import {
  createProvider,
  getChainDiamondProxy,
  getInteropChainIds,
  getL1RpcUrl,
  getL2RpcUrl,
} from "../../src/core/utils";
import { encodeEvmChainAddress } from "../../src/helpers/erc7930";
import { getInteropProtocolFee, sendInteropMessage } from "../../src/helpers/interop-helpers";
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
 * 15 - Interop peer whitelist
 *
 * Governance removes an allowed pair from one side, and the chain's admin allows it again, see
 * {protocol-docs/interop-gating.md#interop-peer-whitelist}. The tests run in order: each starts from the state the
 * previous one left.
 *
 * Topology: interopChainIds[0] removes interopChainIds[1]; the peer's own side stays allowed.
 */
describe("15 - Interop peer whitelist", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let chainId: number;
  let peerChainId: number;
  let registrar: InteropChainRegistrar;
  let sender: ethers.Contract;
  let chainProvider: ethers.providers.JsonRpcProvider;
  let peerProvider: ethers.providers.JsonRpcProvider;
  let chainBridgehub: ethers.Contract;
  let peerBridgehub: ethers.Contract;

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    const interopChainIds = getInteropChainIds(state.chains.config);
    if (interopChainIds.length < 2) {
      throw new Error("Need at least 2 interop chains for interop peer whitelist tests");
    }
    [chainId, peerChainId] = interopChainIds;

    const l1RpcUrl = getL1RpcUrl(state);
    registrar = new InteropChainRegistrar(l1RpcUrl, state.l1Addresses);
    sender = new ethers.Contract(
      state.l1Addresses.chainRegistrationSender,
      getAbi("ChainRegistrationSender"),
      createProvider(l1RpcUrl)
    );
    chainProvider = createProvider(getL2RpcUrl(state, chainId));
    peerProvider = createProvider(getL2RpcUrl(state, peerChainId));
    chainBridgehub = new ethers.Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), chainProvider);
    peerBridgehub = new ethers.Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), peerProvider);
  });

  it("governance removes an allowed peer from the chain's side only", async () => {
    await registrar.deregisterInteropPair(
      chainId,
      peerChainId,
      getChainDiamondProxy(state.chainAddresses!, chainId),
      chainProvider
    );

    expect(await sender.interopPeerAllowed(peerChainId, chainId), "the peer's side on L1").to.be.true;
    expect(await peerBridgehub.isPeerAllowed(chainId), "the peer's side on its L2Bridgehub").to.be.true;
  });

  it("rejects transfers from the chain to the removed peer", async () => {
    const sourceToken = state.testTokens![chainId];
    const sourceBefore = await captureBalance(chainProvider, sourceToken);

    await expectRevert(
      () =>
        executeTokenTransfer({
          sourceChainId: chainId,
          targetChainId: peerChainId,
          amount: "3",
          sourceTokenAddress: sourceToken,
          logger: (line: string) => console.log(`[interop] ${line}`),
        }),
      "transfer to a removed peer",
      customError("InteropCenter", "DestinationChainNotRegistered(uint256)", [peerChainId]),
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

  it("lets the peer still send to the chain, whose receive filter rejects it", async () => {
    // Contracts don't enforce the receive filter yet: the chain's operator does, offchain, from the flag below
    // ({protocol-docs/interop-gating.md#receive-filter}). So the test stops at the send, which only the
    // peer's own side gates.
    await sendInteropMessage({
      sourceProvider: peerProvider,
      recipient: encodeEvmChainAddress(getInteropSourceAddress(), chainId),
      payload: "0x",
      attributes: [],
      value: await getInteropProtocolFee(peerProvider),
    });

    expect(await chainBridgehub.isPeerAllowed(peerChainId), "the flag the chain's receive filter reads").to.be.false;
  });

  it("transfers from the chain to the peer once its admin allows the peer again", async () => {
    await registrar.allowInteropPeer(
      chainId,
      peerChainId,
      getChainDiamondProxy(state.chainAddresses!, chainId),
      chainProvider
    );

    await expectTokenTransfer({
      sourceChainId: chainId,
      targetChainId: peerChainId,
      amount: randomBigNumber(TOKEN_AMOUNT_MIN, TOKEN_AMOUNT_MAX),
      logger: (line: string) => console.log(`[interop] ${line}`),
    });
  });
});
