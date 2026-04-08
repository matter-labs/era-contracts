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
import { encodeEvmAddress } from "../../src/helpers/erc7930";
import {
  sendInteropBundle,
  executeBundle,
  interopCallValueAttr,
  indirectCallAttr,
  executionAddressAttr,
  getTokenTransferData,
  getInteropProtocolFee,
  deployDummyInteropRecipient,
} from "../../src/helpers/interop-helpers";
import type { CallStarter } from "../../src/helpers/interop-helpers";
import {
  captureBalance,
  getNativeBalance,
  getTokenBalance,
  getTokenAddressForAsset,
  approveTokenForNtv,
  expectNativeSpend,
  expectBalanceDelta,
  expectRevert,
  randomBigNumber,
} from "../../src/helpers/balance-helpers";

// Randomized per-test amount ranges (small enough for balance safety, large enough to detect)
const BASE_TOKEN_MIN = ethers.utils.parseUnits("10", "gwei");
const BASE_TOKEN_MAX = ethers.utils.parseUnits("1000", "gwei");
const ERC20_TOKEN_MIN = BigNumber.from(100);
const ERC20_TOKEN_MAX = BigNumber.from(10000);

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

  // Interop protocol fee (per call)
  let interopFee: BigNumber;

  // DummyInteropRecipient contracts on destination chain (required for direct calls)
  let dummyRecipient1: string;
  let dummyRecipient2: string;

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

    // Query the per-call interop protocol fee
    interopFee = await getInteropProtocolFee(sourceProvider);
    console.log(`   Interop protocol fee: ${interopFee.toString()}`);

    // Deploy DummyInteropRecipient contracts on destination chain for direct-call tests
    dummyRecipient1 = await deployDummyInteropRecipient(destProvider);
    dummyRecipient2 = await deployDummyInteropRecipient(destProvider);
    console.log(`   DummyInteropRecipient 1: ${dummyRecipient1}`);
    console.log(`   DummyInteropRecipient 2: ${dummyRecipient2}`);
  });

  it("can send and execute a single direct call bundle", async () => {
    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const msgValue = interopFee.add(amount);

    const callStarters: CallStarter[] = [
      {
        to: encodeEvmAddress(dummyRecipient1),
        data: "0x",
        callAttributes: [interopCallValueAttr(amount)],
      },
    ];

    const bundleAttributes = [executionAddressAttr(ANVIL_DEFAULT_ACCOUNT_ADDR)];

    const balBefore = await captureBalance(sourceProvider);

    const sendResult = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters,
      bundleAttributes,
      value: msgValue,
    });

    const balAfter = await captureBalance(sourceProvider);

    expect(sendResult.txHash, "single direct call: tx hash should exist").to.not.be.null;
    expect(sendResult.interopBundle, "single direct call: interopBundle should exist").to.not.be.null;

    expectNativeSpend(balBefore, balAfter, msgValue, sendResult.receipt, "single direct call");

    console.log("   [send] Single direct call bundle sent");

    // ── Execute on destination ──
    const recipientBefore = await getNativeBalance(destProvider, dummyRecipient1);

    const receipt = await executeBundle(destProvider, sendResult.bundleData, sourceChainId);

    expect(receipt.status, "single direct call: executeBundle tx should succeed").to.equal(1);

    const recipientAfter = await getNativeBalance(destProvider, dummyRecipient1);
    expectBalanceDelta(recipientBefore, recipientAfter, amount, "single direct call: recipient native");

    console.log("   [receive] Single direct call bundle executed");
  });

  it("can send and execute a single indirect call bundle", async () => {
    const tokenAmount = randomBigNumber(ERC20_TOKEN_MIN, ERC20_TOKEN_MAX);
    const msgValue = interopFee;

    await approveTokenForNtv(sourceProvider, sourceTokenAddress, tokenAmount);

    const callStarters: CallStarter[] = [
      {
        to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
        data: getTokenTransferData(sourceAssetId, tokenAmount, ANVIL_RECIPIENT_ADDR),
        callAttributes: [indirectCallAttr()],
      },
    ];

    const balBefore = await captureBalance(sourceProvider, sourceTokenAddress);

    const sendResult = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters,
      value: msgValue,
    });

    const balAfter = await captureBalance(sourceProvider, sourceTokenAddress);

    expect(sendResult.txHash, "single indirect call: tx hash should exist").to.not.be.null;
    expect(sendResult.interopBundle, "single indirect call: interopBundle should exist").to.not.be.null;

    expectNativeSpend(balBefore, balAfter, msgValue, sendResult.receipt, "single indirect call");

    // Token balance should decrease by exactly tokenAmount
    expect(
      balAfter.token!.eq(balBefore.token!.sub(tokenAmount)),
      "single indirect call: sender token should decrease by tokenAmount"
    ).to.be.true;

    console.log("   [send] Single indirect call bundle sent");

    // ── Execute on destination ──
    // Token may not exist on dest chain yet — resolve after execution
    let destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);
    const recipientTokenBefore = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);

    const receipt = await executeBundle(destProvider, sendResult.bundleData, sourceChainId);

    expect(receipt.status, "single indirect call: executeBundle tx should succeed").to.equal(1);

    // Re-resolve token address (NTV may have deployed the bridged token during executeBundle)
    destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);

    const recipientTokenAfter = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);
    expectBalanceDelta(recipientTokenBefore, recipientTokenAfter, tokenAmount, "single indirect call: recipient token");

    console.log("   [receive] Single indirect call bundle executed");
  });

  it("can send and execute a two direct call bundle", async () => {
    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const msgValue = interopFee.mul(2).add(amount.mul(2));

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

    const balBefore = await captureBalance(sourceProvider);

    const sendResult = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters,
      bundleAttributes,
      value: msgValue,
    });

    const balAfter = await captureBalance(sourceProvider);

    expect(sendResult.txHash, "two direct calls: tx hash should exist").to.not.be.null;
    expect(sendResult.interopBundle, "two direct calls: interopBundle should exist").to.not.be.null;

    expectNativeSpend(balBefore, balAfter, msgValue, sendResult.receipt, "two direct calls");

    console.log("   [send] Two direct calls bundle sent");

    // ── Execute on destination ──
    const recipient1Before = await getNativeBalance(destProvider, dummyRecipient1);
    const recipient2Before = await getNativeBalance(destProvider, dummyRecipient2);

    const receipt = await executeBundle(destProvider, sendResult.bundleData, sourceChainId);

    expect(receipt.status, "two direct calls: executeBundle tx should succeed").to.equal(1);

    const recipient1After = await getNativeBalance(destProvider, dummyRecipient1);
    const recipient2After = await getNativeBalance(destProvider, dummyRecipient2);

    expectBalanceDelta(recipient1Before, recipient1After, amount, "two direct calls: recipient1 native");
    expectBalanceDelta(recipient2Before, recipient2After, amount, "two direct calls: recipient2 native");

    console.log("   [receive] Two direct calls bundle executed");
  });

  it("can send and execute a two indirect call bundle", async () => {
    const tokenAmount = randomBigNumber(ERC20_TOKEN_MIN, ERC20_TOKEN_MAX);
    const totalTokenAmount = tokenAmount.mul(2);
    const msgValue = interopFee.mul(2);

    await approveTokenForNtv(sourceProvider, sourceTokenAddress, totalTokenAmount);

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

    const balBefore = await captureBalance(sourceProvider, sourceTokenAddress);

    const sendResult = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters,
      value: msgValue,
    });

    const balAfter = await captureBalance(sourceProvider, sourceTokenAddress);

    expect(sendResult.txHash, "two indirect calls: tx hash should exist").to.not.be.null;
    expect(sendResult.interopBundle, "two indirect calls: interopBundle should exist").to.not.be.null;

    expectNativeSpend(balBefore, balAfter, msgValue, sendResult.receipt, "two indirect calls");

    expect(
      balAfter.token!.eq(balBefore.token!.sub(totalTokenAmount)),
      "two indirect calls: sender token should decrease by 2x tokenAmount"
    ).to.be.true;

    console.log("   [send] Two indirect calls bundle sent");

    // ── Execute on destination ──
    let destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);
    const recipient1TokenBefore = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);
    const recipient2TokenBefore = await getTokenBalance(destProvider, destTokenAddress, ANVIL_ACCOUNT2_ADDR);

    const receipt = await executeBundle(destProvider, sendResult.bundleData, sourceChainId);

    expect(receipt.status, "two indirect calls: executeBundle tx should succeed").to.equal(1);

    destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);
    const recipient1TokenAfter = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);
    const recipient2TokenAfter = await getTokenBalance(destProvider, destTokenAddress, ANVIL_ACCOUNT2_ADDR);

    expectBalanceDelta(
      recipient1TokenBefore,
      recipient1TokenAfter,
      tokenAmount,
      "two indirect calls: recipient1 token"
    );
    expectBalanceDelta(
      recipient2TokenBefore,
      recipient2TokenAfter,
      tokenAmount,
      "two indirect calls: recipient2 token"
    );

    console.log("   [receive] Two indirect calls bundle executed");
  });

  it("can send and execute a mixed call bundle", async () => {
    const valueAmount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const tokenAmount = randomBigNumber(ERC20_TOKEN_MIN, ERC20_TOKEN_MAX);
    const msgValue = interopFee.mul(2).add(valueAmount);

    await approveTokenForNtv(sourceProvider, sourceTokenAddress, tokenAmount);

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

    const balBefore = await captureBalance(sourceProvider, sourceTokenAddress);

    const sendResult = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters,
      bundleAttributes,
      value: msgValue,
    });

    const balAfter = await captureBalance(sourceProvider, sourceTokenAddress);

    expect(sendResult.txHash, "mixed bundle: tx hash should exist").to.not.be.null;
    expect(sendResult.interopBundle, "mixed bundle: interopBundle should exist").to.not.be.null;

    expectNativeSpend(balBefore, balAfter, msgValue, sendResult.receipt, "mixed bundle");

    expect(
      balAfter.token!.eq(balBefore.token!.sub(tokenAmount)),
      "mixed bundle: sender token should decrease by tokenAmount"
    ).to.be.true;

    console.log("   [send] Mixed bundle sent");

    // ── Execute on destination ──
    let destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);
    const recipientTokenBefore = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);
    const recipient2NativeBefore = await getNativeBalance(destProvider, dummyRecipient2);

    const receipt = await executeBundle(destProvider, sendResult.bundleData, sourceChainId);

    expect(receipt.status, "mixed bundle: executeBundle tx should succeed").to.equal(1);

    destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);
    const recipientTokenAfter = await getTokenBalance(destProvider, destTokenAddress, ANVIL_RECIPIENT_ADDR);
    const recipient2NativeAfter = await getNativeBalance(destProvider, dummyRecipient2);

    expectBalanceDelta(recipientTokenBefore, recipientTokenAfter, tokenAmount, "mixed bundle: recipient token");
    expectBalanceDelta(recipient2NativeBefore, recipient2NativeAfter, valueAmount, "mixed bundle: recipient2 native");

    console.log("   [receive] Mixed bundle executed");
  });

  // ─── Edge cases ──────────────────────────────────────────────

  it("cannot execute the same bundle twice (replay protection)", async () => {
    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const msgValue = interopFee.add(amount);

    const callStarters: CallStarter[] = [
      {
        to: encodeEvmAddress(dummyRecipient1),
        data: "0x",
        callAttributes: [interopCallValueAttr(amount)],
      },
    ];

    const bundleAttributes = [executionAddressAttr(ANVIL_DEFAULT_ACCOUNT_ADDR)];

    const sendResult = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters,
      bundleAttributes,
      value: msgValue,
    });

    // First execution should succeed
    const receipt = await executeBundle(destProvider, sendResult.bundleData, sourceChainId);
    expect(receipt.status).to.equal(1);

    // Second execution with same data should revert
    await expectRevert(() => executeBundle(destProvider, sendResult.bundleData, sourceChainId), "replay executeBundle");

    console.log("   [edge] Replay protection verified");
  });

  it("cannot execute a bundle from a non-matching executionAddress", async () => {
    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const msgValue = interopFee.add(amount);

    const callStarters: CallStarter[] = [
      {
        to: encodeEvmAddress(dummyRecipient1),
        data: "0x",
        callAttributes: [interopCallValueAttr(amount)],
      },
    ];

    // Set executionAddress to a specific address (ANVIL_RECIPIENT_ADDR)
    const bundleAttributes = [executionAddressAttr(ANVIL_RECIPIENT_ADDR)];

    const sendResult = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters,
      bundleAttributes,
      value: msgValue,
    });

    // Attempt to execute from the default account (which is NOT the executionAddress)
    await expectRevert(
      () => executeBundle(destProvider, sendResult.bundleData, sourceChainId),
      "execute from wrong executionAddress"
    );

    console.log("   [edge] executionAddress enforcement verified");
  });

  it("accepts a bundle with zero calls", async () => {
    // The protocol allows empty bundles — they can be sent, verified, and executed.
    const bundleAttributes = [executionAddressAttr(ANVIL_DEFAULT_ACCOUNT_ADDR)];

    const sendResult = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters: [],
      bundleAttributes,
      value: 0,
    });

    expect(sendResult.txHash).to.not.be.null;

    const receipt = await executeBundle(destProvider, sendResult.bundleData, sourceChainId);
    expect(receipt.status).to.equal(1);

    console.log("   [edge] Zero-call bundle accepted and executed");
  });

  it("rejects a bundle with excess msg.value", async () => {
    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const correctValue = interopFee.add(amount);
    const excessValue = correctValue.add(ethers.utils.parseEther("1"));

    const callStarters: CallStarter[] = [
      {
        to: encodeEvmAddress(dummyRecipient1),
        data: "0x",
        callAttributes: [interopCallValueAttr(amount)],
      },
    ];

    const bundleAttributes = [executionAddressAttr(ANVIL_DEFAULT_ACCOUNT_ADDR)];

    await expectRevert(
      () =>
        sendInteropBundle({
          sourceProvider,
          destinationChainId: destChainId,
          callStarters,
          bundleAttributes,
          value: excessValue,
        }),
      "excess msg.value"
    );

    console.log("   [edge] Excess msg.value rejected");
  });
});
