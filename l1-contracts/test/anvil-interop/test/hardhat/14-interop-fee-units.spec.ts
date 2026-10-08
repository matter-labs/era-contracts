import { expect } from "chai";
import type { BigNumber } from "ethers";
import { Contract, Wallet, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import {
  getChainIdByRole,
  getChainIdsByRole,
  getL2Chain,
  createProvider,
  impersonateAndRun,
} from "../../src/core/utils";
import { getAbi } from "../../src/core/contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, EIP1967_ADMIN_SLOT, INTEROP_CENTER_ADDR } from "../../src/core/const";
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
const PREPAID_AMOUNT = ethers.utils.parseUnits("1", "gwei");

/**
 * 14 - Interop fee units
 *
 * The interop fee pieces on the deployed ecosystem: the InteropCenter counter on real bundles and
 * withdrawals, and the L1 fee manager against the real Bridgehub and diamonds. See
 * {protocol-docs/interop-fee.md}. The harness does not commit batches to L1; the commit-time charge is
 * covered by the foundry suite (BatchProcessing/InteropFee.t.sol).
 */
describe("14 - Interop fee units", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;

  let sourceChainId: number;
  let directSettledChainId: number;
  let destChainId: number;
  let sourceProvider: ethers.providers.JsonRpcProvider;
  let destProvider: ethers.providers.JsonRpcProvider;
  let dummyRecipient: string;
  let l1Provider: ethers.providers.JsonRpcProvider;
  let feeManager: Contract;

  function interopCenter(provider: ethers.providers.JsonRpcProvider): Contract {
    return new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), provider);
  }

  async function feeUnits(provider: ethers.providers.JsonRpcProvider): Promise<BigNumber> {
    return interopCenter(provider).interopFeeUnits();
  }

  async function proxyAdminOf(proxy: string): Promise<string> {
    return ethers.utils.getAddress(
      ethers.utils.hexDataSlice(await l1Provider.getStorageAt(proxy, EIP1967_ADMIN_SLOT), 12)
    );
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
    directSettledChainId = getChainIdByRole(state.chains.config, "directSettled");

    l1Provider = createProvider(state.chains.l1!.rpcUrl);
    feeManager = new Contract(state.ctmAddresses.interopFeeManager, getAbi("InteropFeeManager"), l1Provider);
  });

  it("deploys the L1 fee manager switched off and owned by the CTM's governance", async () => {
    expect(await l1Provider.getCode(feeManager.address), "fee manager must be deployed").to.not.equal("0x");
    expect((await feeManager.feePerUnit()).toString(), "the switch ships off").to.equal("0");
    expect((await feeManager.accruedFees()).toString()).to.equal("0");
    expect(await feeManager.BRIDGE_HUB()).to.equal(state.l1Addresses!.bridgehub);
    // The manager sits behind the CTM's ProxyAdmin, and the governance owning that ProxyAdmin owns the switch and
    // receives the fees from initialization.
    const proxyAdmin = await proxyAdminOf(feeManager.address);
    expect(proxyAdmin).to.equal(await proxyAdminOf(state.ctmAddresses!.chainTypeManager));
    const governance: string = await new Contract(proxyAdmin, getAbi("ProxyAdmin"), l1Provider).owner();
    expect(await feeManager.owner()).to.equal(governance);
    expect(await feeManager.feeRecipient()).to.equal(governance);
    expect(await feeManager.pendingOwner()).to.equal(ethers.constants.AddressZero);
  });

  it("holds a chain's prepaid balance for its admin", async () => {
    const bridgehub = new Contract(state.l1Addresses!.bridgehub, getAbi("L1Bridgehub"), l1Provider);
    const diamond = new Contract(await bridgehub.getZKChain(directSettledChainId), getAbi("GettersFacet"), l1Provider);
    const chainAdmin: string = await diamond.getAdmin();
    const receiver = Wallet.createRandom().address;
    const balanceBefore = await feeManager.chainBalance(directSettledChainId);

    const depositor = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
    await (await feeManager.connect(depositor).deposit(directSettledChainId, { value: PREPAID_AMOUNT })).wait();
    expect((await feeManager.chainBalance(directSettledChainId)).toString()).to.equal(
      balanceBefore.add(PREPAID_AMOUNT).toString()
    );

    await impersonateAndRun(l1Provider, chainAdmin, async (adminSigner) => {
      await (await feeManager.connect(adminSigner).withdraw(directSettledChainId, receiver, PREPAID_AMOUNT)).wait();
    });
    expect((await feeManager.chainBalance(directSettledChainId)).toString()).to.equal(balanceBefore.toString());
    expect((await l1Provider.getBalance(receiver)).toString()).to.equal(PREPAID_AMOUNT.toString());
  });

  it("counts every call of an L2->L2 bundle on the source chain only", async () => {
    const sourceBefore = await feeUnits(sourceProvider);
    const destBefore = await feeUnits(destProvider);

    const single = await sendDirectCalls(1);
    expect((await feeUnits(sourceProvider)).sub(sourceBefore).toString(), "one call").to.equal("1");

    const triple = await sendDirectCalls(3);
    expect((await feeUnits(sourceProvider)).sub(sourceBefore).toString(), "one + three calls").to.equal("4");

    // Executing on the destination is not sending: the destination's counter does not move.
    expect((await executeBundle(destProvider, single.bundleData, sourceChainId)).status).to.equal(1);
    expect((await executeBundle(destProvider, triple.bundleData, sourceChainId)).status).to.equal(1);
    expect((await feeUnits(destProvider)).toString(), "destination counter unchanged").to.equal(destBefore.toString());
  });

  it("does not count withdrawals to L1", async () => {
    const withdrawingChain = getL2Chain(state.chains!, directSettledChainId);
    const provider = createProvider(withdrawingChain.rpcUrl);
    const before = await feeUnits(provider);

    await initiateEthWithdrawal({
      l2RpcUrl: withdrawingChain.rpcUrl,
      l1RpcUrl: state.chains!.l1!.rpcUrl,
      chainId: directSettledChainId,
      l1Addresses: state.l1Addresses!,
      amount: WITHDRAWAL_AMOUNT,
    });

    expect((await feeUnits(provider)).toString(), "withdrawal must not be counted").to.equal(before.toString());
  });
});
