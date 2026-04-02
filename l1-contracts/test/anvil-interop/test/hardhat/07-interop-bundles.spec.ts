import { expect } from "chai";
import { BigNumber, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole, getL2Chain } from "../../src/core/utils";
import { encodeNtvAssetId } from "../../src/core/data-encoding";
import {
  ANVIL_DEFAULT_ACCOUNT_ADDR,
  ANVIL_RECIPIENT_ADDR,
  ANVIL_ACCOUNT2_ADDR,
  L2_ASSET_ROUTER_ADDR,
} from "../../src/core/const";
import {
  sendInteropBundle,
  executeBundle,
  encodeEvmAddress,
  interopCallValueAttr,
  indirectCallAttr,
  executionAddressAttr,
  getTokenTransferData,
  captureSourceBalance,
  getNativeBalance,
  getTokenBalance,
  getTokenAddressForAsset,
  approveAndReturnAmount,
  getInteropProtocolFee,
  deployDummyInteropRecipient,
} from "../../src/helpers/interop-bundle-helper";
import type { CallStarter, SendBundleResult } from "../../src/helpers/interop-bundle-helper";

/** Base token transfer amount (100 gwei — small enough to avoid balance issues, large enough to detect). */
const BASE_TOKEN_AMOUNT = ethers.utils.parseUnits("100", "gwei");

/** ERC20 token transfer amount (500 smallest units). */
const ERC20_TOKEN_AMOUNT = BigNumber.from(500);

describe("07 - Interop Bundles (GW-settled chains)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let gwSettledChainIds: number[];

  // Chain providers
  let sourceChainId: number;
  let destChainId: number;
  let sourceProvider: ethers.providers.JsonRpcProvider;
  let destProvider: ethers.providers.JsonRpcProvider;

  // Token-related values resolved per-chain
  let sourceTokenAddress: string;
  let sourceAssetId: string;
  let destTokenAddress: string;

  // Interop protocol fee (per call)
  let interopProtocolFee: BigNumber;

  // DummyInteropRecipient contracts on destination chain (required for direct calls)
  let dummyRecipient1: string;
  let dummyRecipient2: string;

  // Stored bundle results from the "send" test, consumed by the "receive" tests
  let singleDirectBundle: SendBundleResult;
  let singleIndirectBundle: SendBundleResult;
  let twoDirectBundle: SendBundleResult;
  let twoIndirectBundle: SendBundleResult;
  let mixedBundle: SendBundleResult;

  before(async () => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }

    gwSettledChainIds = getChainIdsByRole(state.chains.config, "gwSettled");
    if (gwSettledChainIds.length < 2) {
      throw new Error("Need at least 2 GW-settled chains for interop bundle tests");
    }

    sourceChainId = gwSettledChainIds[0];
    destChainId = gwSettledChainIds[1];

    const sourceChain = getL2Chain(state.chains!, sourceChainId);
    const destChain = getL2Chain(state.chains!, destChainId);
    sourceProvider = new ethers.providers.JsonRpcProvider(sourceChain.rpcUrl);
    destProvider = new ethers.providers.JsonRpcProvider(destChain.rpcUrl);

    sourceTokenAddress = state.testTokens![sourceChainId];
    sourceAssetId = encodeNtvAssetId(sourceChainId, sourceTokenAddress);

    // Resolve the destination-side L2 token address for this asset
    destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);

    // Query the per-call interop protocol fee
    interopProtocolFee = await getInteropProtocolFee(sourceProvider);
    console.log(`   Interop protocol fee: ${interopProtocolFee.toString()}`);

    // Deploy DummyInteropRecipient contracts on destination chain for direct-call tests
    dummyRecipient1 = await deployDummyInteropRecipient(destProvider);
    dummyRecipient2 = await deployDummyInteropRecipient(destProvider);
    console.log(`   DummyInteropRecipient 1: ${dummyRecipient1}`);
    console.log(`   DummyInteropRecipient 2: ${dummyRecipient2}`);
  });

  // ─── Sending bundles ──────────────────────────────────────────

  it("can send bundles", async () => {
    // ── Sub-scenario 1: Single direct call ──
    {
      const amount = BASE_TOKEN_AMOUNT;
      const msgValue = interopProtocolFee.add(amount);

      const callStarters: CallStarter[] = [
        {
          to: encodeEvmAddress(dummyRecipient1),
          data: "0x",
          callAttributes: [interopCallValueAttr(amount)],
        },
      ];

      const bundleAttributes = [executionAddressAttr(ANVIL_DEFAULT_ACCOUNT_ADDR)];

      const balBefore = await captureSourceBalance(sourceProvider);

      singleDirectBundle = await sendInteropBundle({
        sourceProvider,
        destinationChainId: destChainId,
        callStarters,
        bundleAttributes,
        value: msgValue,
      });

      const balAfter = await captureSourceBalance(sourceProvider);

      expect(singleDirectBundle.txHash, "single direct call: tx hash should exist").to.not.be.null;
      expect(singleDirectBundle.interopBundle, "single direct call: interopBundle should exist").to.not.be.null;

      // Native balance should decrease by at least msgValue (gas costs make exact match impossible)
      expect(
        balAfter.native.lte(balBefore.native.sub(msgValue)),
        "single direct call: sender native balance should decrease by at least msgValue"
      ).to.equal(true);

      console.log("   [send] Single direct call bundle sent");
    }

    // ── Sub-scenario 2: Single indirect call (ERC20 via L2AssetRouter) ──
    {
      const tokenAmount = ERC20_TOKEN_AMOUNT;
      const msgValue = interopProtocolFee;

      await approveAndReturnAmount(sourceProvider, sourceTokenAddress, tokenAmount);

      const callStarters: CallStarter[] = [
        {
          to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
          data: getTokenTransferData(sourceAssetId, tokenAmount, ANVIL_RECIPIENT_ADDR),
          callAttributes: [indirectCallAttr()],
        },
      ];

      const balBefore = await captureSourceBalance(sourceProvider, sourceTokenAddress);

      singleIndirectBundle = await sendInteropBundle({
        sourceProvider,
        destinationChainId: destChainId,
        callStarters,
        value: msgValue,
      });

      const balAfter = await captureSourceBalance(sourceProvider, sourceTokenAddress);

      expect(singleIndirectBundle.txHash, "single indirect call: tx hash should exist").to.not.be.null;
      expect(singleIndirectBundle.interopBundle, "single indirect call: interopBundle should exist").to.not.be.null;

      // Native balance should decrease by at least msgValue
      expect(
        balAfter.native.lte(balBefore.native.sub(msgValue)),
        "single indirect call: sender native balance should decrease by at least msgValue"
      ).to.equal(true);

      // Token balance should decrease by exactly tokenAmount
      expect(
        balAfter.token!.eq(balBefore.token!.sub(tokenAmount)),
        "single indirect call: sender token balance should decrease by exactly tokenAmount"
      ).to.equal(true);

      console.log("   [send] Single indirect call bundle sent");
    }

    // ── Sub-scenario 3: Two direct calls ──
    {
      const amount = BASE_TOKEN_AMOUNT;
      const msgValue = interopProtocolFee.mul(2).add(amount.mul(2));

      const callStarters: CallStarter[] = [
        {
          to: encodeEvmAddress(dummyRecipient1),
          data: "0x",
          callAttributes: [interopCallValueAttr(amount)],
        },
        {
          to: encodeEvmAddress(dummyRecipient2),
          data: "0x",
          callAttributes: [interopCallValueAttr(amount)],
        },
      ];

      const bundleAttributes = [executionAddressAttr(ANVIL_DEFAULT_ACCOUNT_ADDR)];

      const balBefore = await captureSourceBalance(sourceProvider);

      twoDirectBundle = await sendInteropBundle({
        sourceProvider,
        destinationChainId: destChainId,
        callStarters,
        bundleAttributes,
        value: msgValue,
      });

      const balAfter = await captureSourceBalance(sourceProvider);

      expect(twoDirectBundle.txHash, "two direct calls: tx hash should exist").to.not.be.null;
      expect(twoDirectBundle.interopBundle, "two direct calls: interopBundle should exist").to.not.be.null;

      expect(
        balAfter.native.lte(balBefore.native.sub(msgValue)),
        "two direct calls: sender native balance should decrease by at least msgValue"
      ).to.equal(true);

      console.log("   [send] Two direct calls bundle sent");
    }

    // ── Sub-scenario 4: Two indirect calls ──
    {
      const tokenAmount = ERC20_TOKEN_AMOUNT;
      const totalTokenAmount = tokenAmount.mul(2);
      const msgValue = interopProtocolFee.mul(2);

      await approveAndReturnAmount(sourceProvider, sourceTokenAddress, totalTokenAmount);

      const callStarters: CallStarter[] = [
        {
          to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
          data: getTokenTransferData(sourceAssetId, tokenAmount, ANVIL_RECIPIENT_ADDR),
          callAttributes: [indirectCallAttr()],
        },
        {
          to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
          data: getTokenTransferData(sourceAssetId, tokenAmount, ANVIL_ACCOUNT2_ADDR),
          callAttributes: [indirectCallAttr()],
        },
      ];

      const balBefore = await captureSourceBalance(sourceProvider, sourceTokenAddress);

      twoIndirectBundle = await sendInteropBundle({
        sourceProvider,
        destinationChainId: destChainId,
        callStarters,
        value: msgValue,
      });

      const balAfter = await captureSourceBalance(sourceProvider, sourceTokenAddress);

      expect(twoIndirectBundle.txHash, "two indirect calls: tx hash should exist").to.not.be.null;
      expect(twoIndirectBundle.interopBundle, "two indirect calls: interopBundle should exist").to.not.be.null;

      expect(
        balAfter.native.lte(balBefore.native.sub(msgValue)),
        "two indirect calls: sender native balance should decrease by at least msgValue"
      ).to.equal(true);

      expect(
        balAfter.token!.eq(balBefore.token!.sub(totalTokenAmount)),
        "two indirect calls: sender token balance should decrease by exactly 2x tokenAmount"
      ).to.equal(true);

      console.log("   [send] Two indirect calls bundle sent");
    }

    // ── Sub-scenario 5: Mixed bundle (one token transfer + one value transfer) ──
    {
      const valueAmount = BASE_TOKEN_AMOUNT;
      const tokenAmount = ERC20_TOKEN_AMOUNT;
      const msgValue = interopProtocolFee.mul(2).add(valueAmount);

      await approveAndReturnAmount(sourceProvider, sourceTokenAddress, tokenAmount);

      const callStarters: CallStarter[] = [
        {
          to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
          data: getTokenTransferData(sourceAssetId, tokenAmount, ANVIL_RECIPIENT_ADDR),
          callAttributes: [indirectCallAttr()],
        },
        {
          to: encodeEvmAddress(dummyRecipient2),
          data: "0x",
          callAttributes: [interopCallValueAttr(valueAmount)],
        },
      ];

      const bundleAttributes = [executionAddressAttr(ANVIL_DEFAULT_ACCOUNT_ADDR)];

      const balBefore = await captureSourceBalance(sourceProvider, sourceTokenAddress);

      mixedBundle = await sendInteropBundle({
        sourceProvider,
        destinationChainId: destChainId,
        callStarters,
        bundleAttributes,
        value: msgValue,
      });

      const balAfter = await captureSourceBalance(sourceProvider, sourceTokenAddress);

      expect(mixedBundle.txHash, "mixed bundle: tx hash should exist").to.not.be.null;
      expect(mixedBundle.interopBundle, "mixed bundle: interopBundle should exist").to.not.be.null;

      expect(
        balAfter.native.lte(balBefore.native.sub(msgValue)),
        "mixed bundle: sender native balance should decrease by at least msgValue"
      ).to.equal(true);

      expect(
        balAfter.token!.eq(balBefore.token!.sub(tokenAmount)),
        "mixed bundle: sender token balance should decrease by exactly tokenAmount"
      ).to.equal(true);

      console.log("   [send] Mixed bundle sent");
    }
  });

  // ─── Receiving / executing bundles ────────────────────────────

  it("can receive a single direct call bundle", async () => {
    const amount = BASE_TOKEN_AMOUNT;

    const recipientBefore = await getNativeBalance(destProvider, dummyRecipient1);

    const receipt = await executeBundle(destProvider, singleDirectBundle.bundleData, sourceChainId);

    expect(receipt.status, "single direct call: executeBundle tx should succeed").to.equal(1);

    const recipientAfter = await getNativeBalance(destProvider, dummyRecipient1);
    const recipientDelta = recipientAfter.sub(recipientBefore);

    expect(
      recipientDelta.eq(amount),
      `single direct call: recipient native balance should increase by exactly ${amount.toString()}, got ${recipientDelta.toString()}`
    ).to.equal(true);

    console.log("   [receive] Single direct call bundle executed");
  });

  it("can receive a single indirect call bundle", async () => {
    const tokenAmount = ERC20_TOKEN_AMOUNT;

    // Token may not exist on dest chain yet — resolve after execution
    const recipientTokenBefore = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);

    const receipt = await executeBundle(destProvider, singleIndirectBundle.bundleData, sourceChainId);

    expect(receipt.status, "single indirect call: executeBundle tx should succeed").to.equal(1);

    // Re-resolve token address (NTV may have deployed the bridged token during executeBundle)
    destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);

    const recipientTokenAfter = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);
    const recipientTokenDelta = recipientTokenAfter.sub(recipientTokenBefore);

    expect(
      recipientTokenDelta.eq(tokenAmount),
      `single indirect call: recipient token balance should increase by exactly ${tokenAmount.toString()}, got ${recipientTokenDelta.toString()}`
    ).to.equal(true);

    console.log("   [receive] Single indirect call bundle executed");
  });

  it("can receive a two direct call bundle", async () => {
    const amount = BASE_TOKEN_AMOUNT;

    const recipient1Before = await getNativeBalance(destProvider, dummyRecipient1);
    const recipient2Before = await getNativeBalance(destProvider, dummyRecipient2);

    const receipt = await executeBundle(destProvider, twoDirectBundle.bundleData, sourceChainId);

    expect(receipt.status, "two direct calls: executeBundle tx should succeed").to.equal(1);

    const recipient1After = await getNativeBalance(destProvider, dummyRecipient1);
    const recipient2After = await getNativeBalance(destProvider, dummyRecipient2);

    const recipient1Delta = recipient1After.sub(recipient1Before);
    const recipient2Delta = recipient2After.sub(recipient2Before);

    expect(
      recipient1Delta.eq(amount),
      `two direct calls: recipient1 native balance should increase by exactly ${amount.toString()}, got ${recipient1Delta.toString()}`
    ).to.equal(true);

    expect(
      recipient2Delta.eq(amount),
      `two direct calls: recipient2 native balance should increase by exactly ${amount.toString()}, got ${recipient2Delta.toString()}`
    ).to.equal(true);

    console.log("   [receive] Two direct calls bundle executed");
  });

  it("can receive a two indirect call bundle", async () => {
    const tokenAmount = ERC20_TOKEN_AMOUNT;

    const recipient1TokenBefore = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);
    const recipient2TokenBefore = await getTokenBalance(destProvider, destTokenAddress, ANVIL_ACCOUNT2_ADDR);

    const receipt = await executeBundle(destProvider, twoIndirectBundle.bundleData, sourceChainId);

    expect(receipt.status, "two indirect calls: executeBundle tx should succeed").to.equal(1);

    const recipient1TokenAfter = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);
    const recipient2TokenAfter = await getTokenBalance(destProvider, destTokenAddress, ANVIL_ACCOUNT2_ADDR);

    const recipient1TokenDelta = recipient1TokenAfter.sub(recipient1TokenBefore);
    const recipient2TokenDelta = recipient2TokenAfter.sub(recipient2TokenBefore);

    expect(
      recipient1TokenDelta.eq(tokenAmount),
      `two indirect calls: recipient1 token balance should increase by exactly ${tokenAmount.toString()}, got ${recipient1TokenDelta.toString()}`
    ).to.equal(true);

    expect(
      recipient2TokenDelta.eq(tokenAmount),
      `two indirect calls: recipient2 token balance should increase by exactly ${tokenAmount.toString()}, got ${recipient2TokenDelta.toString()}`
    ).to.equal(true);

    console.log("   [receive] Two indirect calls bundle executed");
  });

  it("can receive a mixed call bundle", async () => {
    const valueAmount = BASE_TOKEN_AMOUNT;
    const tokenAmount = ERC20_TOKEN_AMOUNT;

    // The mixed bundle has: call[0] = indirect token transfer to ANVIL_RECIPIENT_ADDR,
    //                       call[1] = direct value transfer to dummyRecipient2.
    const recipientTokenBefore = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);
    const recipient2NativeBefore = await getNativeBalance(destProvider, dummyRecipient2);

    const receipt = await executeBundle(destProvider, mixedBundle.bundleData, sourceChainId);

    expect(receipt.status, "mixed bundle: executeBundle tx should succeed").to.equal(1);

    const recipientTokenAfter = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);
    const recipient2NativeAfter = await getNativeBalance(destProvider, dummyRecipient2);

    const recipientTokenDelta = recipientTokenAfter.sub(recipientTokenBefore);
    const recipient2NativeDelta = recipient2NativeAfter.sub(recipient2NativeBefore);

    expect(
      recipientTokenDelta.eq(tokenAmount),
      `mixed bundle: recipient token balance should increase by exactly ${tokenAmount.toString()}, got ${recipientTokenDelta.toString()}`
    ).to.equal(true);

    expect(
      recipient2NativeDelta.eq(valueAmount),
      `mixed bundle: recipient2 native balance should increase by exactly ${valueAmount.toString()}, got ${recipient2NativeDelta.toString()}`
    ).to.equal(true);

    console.log("   [receive] Mixed bundle executed");
  });
});
