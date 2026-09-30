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
import { getL1RpcUrl, getL2RpcUrl, getChainIdByRole, getChainIdsByRole, createProvider } from "../../src/core/utils";

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

describe("05 - Gateway Bridge (GW-settled chain, via GW)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let gwChainId: number;
  let gwSettledChainId: number;

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    gwChainId = getChainIdByRole(state.chains.config, "gateway");
    gwSettledChainId = getChainIdsByRole(state.chains.config, "gwSettled")[0];
  });

  describe("ETH deposits L1 -> GW-settled chain through gateway", () => {
    it("deposits ETH from L1 to GW-settled chain", async () => {
      const l1Provider = createProvider(getL1RpcUrl(state));
      const amount = randomBigNumber(ETH_AMOUNT_MIN, ETH_AMOUNT_MAX);
      const senderAddr = ANVIL_DEFAULT_ACCOUNT_ADDR;
      const recipientAddr = ANVIL_RECIPIENT_ADDR;
      const l2Provider = createProvider(getL2RpcUrl(state, gwSettledChainId));
      const recipientL2Before = await l2Provider.getBalance(recipientAddr);

      const senderL1Before = await l1Provider.getBalance(senderAddr);

      // L1 accounting is the aggregate L1NativeTokenVault.bridgedOut[ETH] — no per-chain
      // attribution ({protocol-docs/bridging.md#native-token-vault}), so it moves the same way as for a
      // direct-settled chain.
      const l1Ntv = state.l1Addresses!.l1NativeTokenVault;
      const ethAssetId = await getL1BaseTokenAssetId(getL1RpcUrl(state), l1Ntv);
      const bridgedOutBefore = await getL1BridgedOut(getL1RpcUrl(state), l1Ntv, ethAssetId);

      const bridgehub = new Contract(state.l1Addresses!.bridgehub, getAbi("L1Bridgehub"), l1Provider);
      const expectedMintValue = amount.add(
        await bridgehub.l2TransactionBaseCost(
          gwSettledChainId,
          ANVIL_INTEROP_PRIORITY_TX_L1_GAS_PRICE_WEI,
          ANVIL_INTEROP_BASE_TOKEN_PRIORITY_TX_GAS_LIMIT,
          ANVIL_INTEROP_REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        )
      );

      const result = await depositETHToL2({
        l1RpcUrl: getL1RpcUrl(state),
        l2RpcUrl: getL2RpcUrl(state, gwSettledChainId),
        chainId: gwSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        gwRpcUrl: getL2RpcUrl(state, gwChainId),
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
      expect(initiated.chainId.toNumber()).to.equal(gwSettledChainId);
      expect(initiated.from).to.equal(senderAddr);
      expect(initiated.assetId).to.equal(ethAssetId);
      expect(initiated.amount.toString()).to.equal(expectedMintValue.toString());

      const senderL1After = await l1Provider.getBalance(senderAddr);

      expectNativeSpend(
        { native: senderL1Before },
        { native: senderL1After },
        expectedMintValue,
        l1Receipt,
        "deposit sender L1"
      );

      const recipientL2After = await l2Provider.getBalance(recipientAddr);
      // The Anvil priority relay forwards l2Value exactly; bootloader fee refunds are not simulated.
      expectBalanceDelta(recipientL2Before, recipientL2After, amount, "gateway deposit recipient L2");

      // L1NativeTokenVault.bridgedOut[ETH] should increase by exactly the bridged amount (mintValue).
      const bridgedOutAfter = await getL1BridgedOut(getL1RpcUrl(state), l1Ntv, ethAssetId);
      const bridgedOutDelta = bridgedOutAfter.sub(bridgedOutBefore);
      expect(
        bridgedOutDelta.eq(expectedMintValue),
        `bridgedOut[ETH] should increase by ${expectedMintValue.toString()}, got ${bridgedOutDelta.toString()}`
      ).to.equal(true);
    });
  });

  describe("ETH withdrawals GW-settled chain -> L1 through gateway", () => {
    it("withdraws ETH from GW-settled chain to L1", async () => {
      const l1Provider = createProvider(getL1RpcUrl(state));
      const amount = randomBigNumber(ETH_AMOUNT_MIN, ETH_AMOUNT_MAX);
      const recipientAddr = ANVIL_RECIPIENT_ADDR;

      const recipientL1Before = await l1Provider.getBalance(recipientAddr);

      const l2Provider = createProvider(getL2RpcUrl(state, gwSettledChainId));
      const senderL2Before = await l2Provider.getBalance(ANVIL_DEFAULT_ACCOUNT_ADDR);

      // Snapshot L1NativeTokenVault.bridgedOut[ETH] before finalizing the withdrawal on L1.
      const l1Ntv = state.l1Addresses!.l1NativeTokenVault;
      const ethAssetId = await getL1BaseTokenAssetId(getL1RpcUrl(state), l1Ntv);
      const bridgedOutBefore = await getL1BridgedOut(getL1RpcUrl(state), l1Ntv, ethAssetId);

      const result = await withdrawETHFromL2({
        l1RpcUrl: getL1RpcUrl(state),
        l2RpcUrl: getL2RpcUrl(state, gwSettledChainId),
        chainId: gwSettledChainId,
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
      expect(sent.interopBundle.sourceChainId.toNumber()).to.equal(gwSettledChainId);
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
      expect(finalized.sourceChainId.toNumber()).to.equal(gwSettledChainId);
      expect(finalized.assetId).to.equal(ethAssetId);
      const minted = expectEvent(l1Receipt, "L1NativeTokenVault", l1Ntv, "BridgeMint");
      expect(minted.chainId.toNumber()).to.equal(gwSettledChainId);
      expect(minted.assetId).to.equal(ethAssetId);
      expect(minted.receiver).to.equal(recipientAddr);
      expect(minted.amount.toString()).to.equal(amount.toString());

      const recipientL1After = await l1Provider.getBalance(recipientAddr);

      // L1NativeTokenVault.bridgedOut[ETH] should decrease by exactly the withdrawn amount.
      const bridgedOutAfter = await getL1BridgedOut(getL1RpcUrl(state), l1Ntv, ethAssetId);
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
