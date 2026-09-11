import { expect } from "chai";
import { Contract, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { depositETHToL2 } from "../../src/helpers/l1-deposit-helper";
import { withdrawETHFromL2 } from "../../src/helpers/l2-withdrawal-helper";
import { getL1BridgedOut, getL1BaseTokenAssetId } from "../../src/helpers/bridged-out-helper";
import {
  ANVIL_INTEROP_BASE_TOKEN_PRIORITY_TX_GAS_LIMIT,
  ANVIL_INTEROP_PRIORITY_TX_L1_GAS_PRICE_WEI,
  ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  ANVIL_DEFAULT_ACCOUNT_ADDR,
  ANVIL_RECIPIENT_ADDR,
  INTEROP_CENTER_ADDR,
} from "../../src/core/const";
import { getL2Chain, getChainIdByRole, createProvider } from "../../src/core/utils";

import { getAbi } from "../../src/core/contracts";
import {
  expectBalanceDelta,
  expectNativeSpend,
  expectSuccessfulReceipt,
  expectEvent,
  randomBigNumber,
} from "../../src/helpers/balance-helpers";

const ETH_AMOUNT_MIN = ethers.utils.parseEther("0.1");
const ETH_AMOUNT_MAX = ethers.utils.parseEther("0.5");

describe("02 - Direct L1<->L2 Bridge (direct-settled chain)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let directSettledChainId: number;

  before(async () => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    directSettledChainId = getChainIdByRole(state.chains.config, "directSettled");
  });

  describe("ETH deposits L1 -> L2", () => {
    it("deposits ETH from L1 to L2", async () => {
      const l1Provider = createProvider(state.chains!.l1!.rpcUrl);
      const senderAddr = ANVIL_DEFAULT_ACCOUNT_ADDR;
      const recipientAddr = ANVIL_RECIPIENT_ADDR;
      const amount = randomBigNumber(ETH_AMOUNT_MIN, ETH_AMOUNT_MAX);
      const l2Chain = getL2Chain(state.chains!, directSettledChainId);
      const l2Provider = createProvider(l2Chain.rpcUrl);

      // Snapshot sender's L1 balance and recipient's L2 balance separately
      const senderL1Before = await l1Provider.getBalance(senderAddr);
      const recipientL2Before = await l2Provider.getBalance(recipientAddr);

      // Snapshot L1NativeTokenVault.bridgedOut[ETH]
      const l1Ntv = state.l1Addresses!.l1NativeTokenVault;
      const ethAssetId = await getL1BaseTokenAssetId(state.chains!.l1!.rpcUrl, l1Ntv);
      const bridgedOutBefore = await getL1BridgedOut(state.chains!.l1!.rpcUrl, l1Ntv, ethAssetId);

      const bridgehub = new Contract(state.l1Addresses!.bridgehub, getAbi("L1Bridgehub"), l1Provider);
      const expectedMintValue = amount.add(
        await bridgehub.l2TransactionBaseCost(
          directSettledChainId,
          ANVIL_INTEROP_PRIORITY_TX_L1_GAS_PRICE_WEI,
          ANVIL_INTEROP_BASE_TOKEN_PRIORITY_TX_GAS_LIMIT,
          ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        )
      );

      const result = await depositETHToL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: directSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        recipient: recipientAddr,
      });

      const l1Receipt = await expectSuccessfulReceipt(l1Provider, result.l1TxHash, "deposit L1");
      await expectSuccessfulReceipt(l2Provider, result.l2TxHash, "deposit L2 relay");
      const initiated = expectEvent(
        l1Receipt,
        "L1AssetRouter",
        state.l1Addresses!.l1SharedBridge,
        "BridgehubDepositBaseTokenInitiated"
      );
      expect(initiated.chainId.toNumber()).to.equal(directSettledChainId);
      expect(initiated.from).to.equal(senderAddr);
      expect(initiated.assetId).to.equal(ethAssetId);
      expect(initiated.amount.toString()).to.equal(expectedMintValue.toString());

      const senderL1After = await l1Provider.getBalance(senderAddr);
      const recipientL2After = await l2Provider.getBalance(recipientAddr);

      // L1NativeTokenVault.bridgedOut[ETH] should increase by exactly the bridged amount (mintValue).
      const bridgedOutAfter = await getL1BridgedOut(state.chains!.l1!.rpcUrl, l1Ntv, ethAssetId);
      const bridgedOutDelta = bridgedOutAfter.sub(bridgedOutBefore);
      expect(
        bridgedOutDelta.eq(expectedMintValue),
        `bridgedOut[ETH] should increase by ${expectedMintValue.toString()}, got ${bridgedOutDelta.toString()}`
      ).to.equal(true);

      expectNativeSpend(
        { native: senderL1Before },
        { native: senderL1After },
        expectedMintValue,
        l1Receipt,
        "deposit sender L1"
      );

      // The Anvil priority relay forwards l2Value exactly; bootloader fee refunds are not simulated.
      expectBalanceDelta(recipientL2Before, recipientL2After, amount, "deposit recipient L2");
    });
  });

  describe("ETH withdrawals L2 -> L1", () => {
    it("withdraws ETH from L2 to L1", async () => {
      const l1Provider = createProvider(state.chains!.l1!.rpcUrl);
      const recipientAddr = ANVIL_RECIPIENT_ADDR;
      const amount = randomBigNumber(ETH_AMOUNT_MIN, ETH_AMOUNT_MAX);
      const l2Chain = getL2Chain(state.chains!, directSettledChainId);

      const l2Provider = createProvider(l2Chain.rpcUrl);
      const senderL2Before = await l2Provider.getBalance(ANVIL_DEFAULT_ACCOUNT_ADDR);

      // Snapshot recipient's L1 balance
      const recipientL1Before = await l1Provider.getBalance(recipientAddr);

      // Snapshot L1NativeTokenVault.bridgedOut[ETH] before finalizing the withdrawal on L1.
      const l1Ntv = state.l1Addresses!.l1NativeTokenVault;
      const ethAssetId = await getL1BaseTokenAssetId(state.chains!.l1!.rpcUrl, l1Ntv);
      const bridgedOutBefore = await getL1BridgedOut(state.chains!.l1!.rpcUrl, l1Ntv, ethAssetId);

      const result = await withdrawETHFromL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: directSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        l1Recipient: recipientAddr,
      });

      const l2Receipt = await expectSuccessfulReceipt(l2Provider, result.l2TxHash, "withdrawal L2");
      const l1Receipt = await expectSuccessfulReceipt(l1Provider, result.l1TxHash, "withdrawal L1 finalization");
      const senderL2After = await l2Provider.getBalance(ANVIL_DEFAULT_ACCOUNT_ADDR);
      expectNativeSpend(
        { native: senderL2Before },
        { native: senderL2After },
        amount,
        l2Receipt,
        "withdrawal sender L2"
      );
      const sent = expectEvent(l2Receipt, "InteropCenter", INTEROP_CENTER_ADDR, "InteropBundleSent");
      expect(sent.interopBundle.sourceChainId.toNumber()).to.equal(directSettledChainId);
      expect(sent.interopBundle.destinationChainId.toNumber()).to.equal(state.chains!.l1!.chainId);
      expect(sent.interopBundle.calls).to.have.length(1);
      const nullifier = new Contract(state.l1Addresses!.l1NullifierProxy, getAbi("L1Nullifier"), l1Provider);
      const handlerAddress = await nullifier.l1InteropHandler();
      const executed = expectEvent(l1Receipt, "L1InteropHandler", handlerAddress, "BundleExecuted");
      expect(executed.bundleHash).to.equal(sent.interopBundleHash);
      const finalized = expectEvent(
        l1Receipt,
        "L1AssetRouter",
        state.l1Addresses!.l1SharedBridge,
        "DepositFinalizedAssetRouter"
      );
      expect(finalized.sourceChainId.toNumber()).to.equal(directSettledChainId);
      expect(finalized.assetId).to.equal(ethAssetId);
      const minted = expectEvent(l1Receipt, "L1NativeTokenVault", l1Ntv, "BridgeMint");
      expect(minted.chainId.toNumber()).to.equal(directSettledChainId);
      expect(minted.assetId).to.equal(ethAssetId);
      expect(minted.receiver).to.equal(recipientAddr);
      expect(minted.amount.toString()).to.equal(amount.toString());

      const recipientL1After = await l1Provider.getBalance(recipientAddr);

      // L1NativeTokenVault.bridgedOut[ETH] should decrease by exactly the withdrawn amount.
      const bridgedOutAfter = await getL1BridgedOut(state.chains!.l1!.rpcUrl, l1Ntv, ethAssetId);
      const bridgedOutDelta = bridgedOutBefore.sub(bridgedOutAfter);
      expect(
        bridgedOutDelta.eq(amount),
        `bridgedOut[ETH] should decrease by ${amount.toString()}, got ${bridgedOutDelta.toString()}`
      ).to.equal(true);

      // Recipient's L1 ETH balance should increase by exactly the withdrawal amount
      const recipientL1Delta = recipientL1After.sub(recipientL1Before);
      expect(
        recipientL1Delta.eq(amount),
        `Recipient L1 ETH balance should increase by ${amount.toString()}, got delta ${recipientL1Delta.toString()}`
      ).to.equal(true);

      console.log(`   Recipient L1 ETH balance delta: ${ethers.utils.formatEther(recipientL1Delta)} ETH`);
    });
  });
});
