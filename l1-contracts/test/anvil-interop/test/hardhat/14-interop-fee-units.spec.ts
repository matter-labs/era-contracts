import { expect } from "chai";
import { BigNumber, Contract, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole, getL2Chain, createProvider } from "../../src/core/utils";
import { getAbi } from "../../src/core/contracts";
import { INTEROP_CENTER_ADDR } from "../../src/core/const";
import { encodeEvmAddress } from "../../src/helpers/erc7930";
import {
  sendInteropBundle,
  executeBundle,
  interopCallValueAttr,
  executionAddressAttr,
  getInteropProtocolFee,
  deployDummyInteropRecipient,
} from "../../src/helpers/interop-helpers";
import type { CallStarter } from "../../src/helpers/interop-helpers";
import { initiateEthWithdrawal } from "../../src/helpers/l2-withdrawal-helper";
import { getInteropSourceAddress } from "../../src/core/accounts";

const CALL_VALUE = ethers.utils.parseUnits("10", "gwei");
const WITHDRAWAL_AMOUNT = ethers.utils.parseUnits("1", "gwei");

/**
 * 14 - Interop fee units
 *
 * The L1 interop fee is charged on the number of interop calls a batch sent, which the source chain's
 * InteropCenter counts in a monotonic counter (see {protocol-docs/interop-fee.md}). This spec runs real
 * bundles between two chains and checks the counter: every call of an L2->L2 bundle counts once on the
 * source, executing a bundle counts nothing on the destination, and withdrawals to L1 are never counted.
 * It also checks that a fresh deployment ships the L1 fee manager switched off.
 *
 * The harness does not commit batches to L1; the commit-time charge is covered by the foundry suite
 * (BatchProcessing/InteropFee.t.sol).
 */
describe("14 - Interop fee units", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;

  let sourceChainId: number;
  let destChainId: number;
  let sourceProvider: ethers.providers.JsonRpcProvider;
  let destProvider: ethers.providers.JsonRpcProvider;
  let dummyRecipient: string;

  function interopCenter(provider: ethers.providers.JsonRpcProvider): Contract {
    return new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), provider);
  }

  async function feeUnits(provider: ethers.providers.JsonRpcProvider): Promise<BigNumber> {
    return interopCenter(provider).interopFeeUnits();
  }

  async function sendDirectCalls(callCount: number) {
    const callStarters: CallStarter[] = [];
    for (let i = 0; i < callCount; ++i) {
      callStarters.push({
        to: encodeEvmAddress(dummyRecipient),
        data: "0x",
        callAttributes: [interopCallValueAttr(CALL_VALUE)],
      });
    }
    const fee = await getInteropProtocolFee(sourceProvider);
    return sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters,
      bundleAttributes: [executionAddressAttr(getInteropSourceAddress())],
      value: fee.add(CALL_VALUE).mul(callCount),
    });
  }

  before(async () => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.ctmAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }

    // The two chains the harness wires for L2<->L2 interop.
    const interopChainIds = getChainIdsByRole(state.chains.config, "gwSettled");
    if (interopChainIds.length < 2) {
      throw new Error("Need at least 2 interop-registered chains");
    }
    sourceChainId = interopChainIds[0];
    destChainId = interopChainIds[1];
    sourceProvider = createProvider(getL2Chain(state.chains, sourceChainId).rpcUrl);
    destProvider = createProvider(getL2Chain(state.chains, destChainId).rpcUrl);

    dummyRecipient = await deployDummyInteropRecipient(destProvider);
  });

  it("deploys the L1 fee manager switched off", async function () {
    const managerAddress = state.ctmAddresses!.interopFeeManager;
    if (!managerAddress) {
      // Pregenerated chain states predate the fee manager; run with ANVIL_INTEROP_FRESH_DEPLOY=1.
      this.skip();
    }
    const l1Provider = createProvider(state.chains!.l1!.rpcUrl);
    const manager = new Contract(managerAddress!, getAbi("InteropFeeManager"), l1Provider);

    expect(await l1Provider.getCode(managerAddress!), "fee manager must be deployed").to.not.equal("0x");
    expect((await manager.feePerUnit()).toString(), "the switch ships off").to.equal("0");
    expect((await manager.accruedFees()).toString()).to.equal("0");
    expect(await manager.BRIDGE_HUB()).to.equal(state.l1Addresses!.bridgehub);
    // Governance owns the switch from initialization; no deployer key ever controls it.
    const owner: string = await manager.owner();
    expect(await l1Provider.getCode(owner), "owner must be the governance contract").to.not.equal("0x");
    expect(await manager.pendingOwner()).to.equal(ethers.constants.AddressZero);
  });

  it("counts every call of an L2->L2 bundle on the source chain only", async () => {
    const sourceBefore = await feeUnits(sourceProvider);
    const destBefore = await feeUnits(destProvider);

    const single = await sendDirectCalls(1);
    expect((await feeUnits(sourceProvider)).sub(sourceBefore).toNumber(), "one call").to.equal(1);

    const triple = await sendDirectCalls(3);
    expect((await feeUnits(sourceProvider)).sub(sourceBefore).toNumber(), "one + three calls").to.equal(4);

    // Executing on the destination is not sending: the destination's counter does not move.
    expect((await executeBundle(destProvider, single.bundleData, sourceChainId)).status).to.equal(1);
    expect((await executeBundle(destProvider, triple.bundleData, sourceChainId)).status).to.equal(1);
    expect((await feeUnits(destProvider)).eq(destBefore), "destination counter unchanged").to.equal(true);
  });

  it("does not count withdrawals to L1", async () => {
    const withdrawingChainId = getChainIdsByRole(state.chains!.config, "directSettled")[0];
    const withdrawingChain = getL2Chain(state.chains!, withdrawingChainId);
    const provider = createProvider(withdrawingChain.rpcUrl);
    const before = await feeUnits(provider);

    await initiateEthWithdrawal({
      l2RpcUrl: withdrawingChain.rpcUrl,
      l1RpcUrl: state.chains!.l1!.rpcUrl,
      chainId: withdrawingChainId,
      l1Addresses: state.l1Addresses!,
      amount: WITHDRAWAL_AMOUNT,
    });

    expect((await feeUnits(provider)).eq(before), "withdrawal must not be counted").to.equal(true);
  });
});
