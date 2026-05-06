import { expect } from "chai";
import { BigNumber, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole, getL2Chain } from "../../src/core/utils";
import { encodeNtvAssetId } from "../../src/core/data-encoding";
import {
  getInteropRecipientAddress,
  getInteropSecondaryRecipientAddress,
  getInteropSourceAddress,
  isLiveInteropMode,
} from "../../src/core/accounts";
import { INTEROP_CENTER_ADDR, L2_ASSET_ROUTER_ADDR } from "../../src/core/const";
import { encodeEvmAddress } from "../../src/helpers/erc7930";
import {
  sendInteropBundle,
  executeBundle,
  simulateExecuteBundle,
  simulateInteropBundle,
  interopCallValueAttr,
  indirectCallAttr,
  executionAddressAttr,
  useFixedFeeAttr,
  getTokenTransferData,
  getInteropProtocolFee,
  getAccumulatedZkFees,
  getZkInteropFee,
  getZkTokenAssetId,
  getZkTokenAddress,
  deployDummyInteropRecipient,
  sendAndExecuteTokenInterop,
} from "../../src/helpers/interop-helpers";
import type { CallStarter } from "../../src/helpers/interop-helpers";
import {
  captureBalance,
  getNativeBalance,
  getTokenBalance,
  getTokenAddressForAsset,
  getAssetIdForToken,
  approveToken,
  approveTokenForNtv,
  expectNativeSpend,
  expectBalanceDelta,
  expectRevert,
  customError,
  randomBigNumber,
} from "../../src/helpers/balance-helpers";
import { deployL2NativeToken } from "../../src/helpers/deploy-test-token";
import { migrateTokenToGateway } from "../../src/helpers/token-balance-migration-helper";

// Randomized per-test amount ranges (small enough for balance safety, large enough to detect)
const BASE_TOKEN_MIN = ethers.utils.parseUnits("10", "gwei");
const BASE_TOKEN_MAX = ethers.utils.parseUnits("1000", "gwei");
const ERC20_TOKEN_MIN = BigNumber.from(100);
const ERC20_TOKEN_MAX = BigNumber.from(10000);
const ROUNDTRIP_TOKEN_TRANSFER_AMOUNT = ethers.utils.parseUnits("1", 18);
const EXCESS_MSG_VALUE_DELTA = BigNumber.from(1);

/**
 * 07 - Interop Bundles (sendBundle / executeBundle)
 *
 * Tests atomic bundle execution across GW-settled chains for direct base-token
 * calls, indirect ERC20 transfers, and mixed bundles. Also covers bundle-level
 * guardrails such as replay protection, executionAddress enforcement, zero-call
 * bundles, and msg.value validation.
 *
 * Topology: gwSettledChainIds[0] = source, gwSettledChainIds[1] = destination
 */
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
  let l1RpcUrl: string;
  let l1Provider: ethers.providers.JsonRpcProvider;
  let gatewayChainId: number;
  let gatewayRpcUrl: string;

  // Token-related values resolved per-chain
  let sourceTokenAddress: string;
  let sourceAssetId: string;
  let sourceZkTokenAddress: string;
  let fixedZkFeeTestsEnabled = false;

  // Interop protocol fee (per call)
  let interopFee: BigNumber;
  let zkInteropFee: BigNumber;

  // DummyInteropRecipient contracts on destination chain (required for direct calls)
  let dummyRecipient1: string;
  let dummyRecipient2: string;

  async function currentInteropFee(): Promise<BigNumber> {
    interopFee = await getInteropProtocolFee(sourceProvider);
    return interopFee;
  }

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

    const gatewayChainIds = getChainIdsByRole(state.chains.config, "gateway");
    if (gatewayChainIds.length !== 1) {
      throw new Error(`Expected exactly one gateway chain in interop state, got ${gatewayChainIds.length}`);
    }
    gatewayChainId = gatewayChainIds[0];
    gatewayRpcUrl = getL2Chain(state.chains, gatewayChainId).rpcUrl;

    if (isLiveInteropMode()) {
      const liveL1RpcUrl = process.env.LIVE_L1_RPC?.trim();
      if (!liveL1RpcUrl) {
        throw new Error("LIVE_L1_RPC is required when ANVIL_INTEROP_LIVE=1");
      }
      l1RpcUrl = liveL1RpcUrl;
    } else {
      if (!state.chains.l1) {
        throw new Error("L1 chain is required for local interop bridge tests");
      }
      l1RpcUrl = state.chains.l1.rpcUrl;
    }
    l1Provider = new ethers.providers.JsonRpcProvider(l1RpcUrl);

    sourceTokenAddress = state.testTokens![sourceChainId];
    sourceAssetId = await getAssetIdForToken(sourceProvider, sourceTokenAddress);

    // Query the per-call interop protocol fee
    interopFee = await getInteropProtocolFee(sourceProvider);
    zkInteropFee = await getZkInteropFee(sourceProvider);
    console.log(`   Interop protocol fee: ${interopFee.toString()}`);
    console.log(`   Fixed ZK interop fee: ${zkInteropFee.toString()}`);

    const zkTokenAssetId = state.zkToken?.assetId || (await getZkTokenAssetId(sourceProvider));
    if (zkTokenAssetId === ethers.constants.HashZero) {
      console.warn("   The ZK token has not yet been bridged to the source chain; fixed ZK fee tests will be skipped.");
    } else {
      sourceZkTokenAddress = await getTokenAddressForAsset(sourceProvider, zkTokenAssetId);
      const interopZkTokenAddress = await getZkTokenAddress(sourceProvider);
      if (
        sourceZkTokenAddress === ethers.constants.AddressZero ||
        interopZkTokenAddress === ethers.constants.AddressZero
      ) {
        console.warn(
          "   The ZK token has not yet been bridged to the source chain; fixed ZK fee tests will be skipped."
        );
      } else {
        expect(interopZkTokenAddress, "InteropCenter should resolve the seeded ZK token").to.equal(
          sourceZkTokenAddress
        );
        const zkBalance = await getTokenBalance(sourceProvider, sourceZkTokenAddress, getInteropSourceAddress());
        if (zkBalance.isZero()) {
          console.warn("   ZK token balance is zero; fixed ZK fee tests will be skipped.");
        } else {
          fixedZkFeeTestsEnabled = true;
        }
      }
    }

    // Deploy DummyInteropRecipient contracts on destination chain for direct-call tests
    dummyRecipient1 = await deployDummyInteropRecipient(destProvider);
    dummyRecipient2 = await deployDummyInteropRecipient(destProvider);
    console.log(`   DummyInteropRecipient 1: ${dummyRecipient1}`);
    console.log(`   DummyInteropRecipient 2: ${dummyRecipient2}`);
  });

  it("can send and execute a single direct call bundle", async () => {
    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const interopFee = await currentInteropFee();
    const msgValue = interopFee.add(amount);

    const callStarters: CallStarter[] = [
      {
        to: encodeEvmAddress(dummyRecipient1),
        data: "0x",
        callAttributes: [interopCallValueAttr(amount)],
      },
    ];

    const bundleAttributes = [executionAddressAttr(getInteropSourceAddress())];

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

  it("can send and execute a single direct call bundle with fixed ZK fees", async function () {
    if (!fixedZkFeeTestsEnabled) {
      this.skip();
    }

    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const bundleAttributes = [executionAddressAttr(getInteropSourceAddress()), useFixedFeeAttr(true)];
    const callStarters: CallStarter[] = [
      {
        to: encodeEvmAddress(dummyRecipient1),
        data: "0x",
        callAttributes: [interopCallValueAttr(amount)],
      },
    ];

    const zkBalance = await getTokenBalance(sourceProvider, sourceZkTokenAddress, getInteropSourceAddress());
    expect(
      zkBalance.gte(zkInteropFee),
      `single direct call fixed fee: sender ZK token balance ${zkBalance.toString()} is below required fee ${zkInteropFee.toString()}`
    ).to.be.true;

    await approveToken(sourceProvider, sourceZkTokenAddress, INTEROP_CENTER_ADDR, zkInteropFee);

    const balBefore = await captureBalance(sourceProvider, sourceZkTokenAddress);
    const sendResult = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters,
      bundleAttributes,
      value: amount,
    });
    const balAfter = await captureBalance(sourceProvider, sourceZkTokenAddress);

    expectNativeSpend(balBefore, balAfter, amount, sendResult.receipt, "single direct call fixed fee");
    expect(
      balAfter.token!.eq(balBefore.token!.sub(zkInteropFee)),
      "single direct call fixed fee: sender ZK token should decrease by the fixed fee"
    ).to.be.true;

    const minedBlock = await sourceProvider.getBlock(sendResult.receipt.blockNumber);
    const accumulatedZkFees = await getAccumulatedZkFees(sourceProvider, minedBlock.miner);
    expect(accumulatedZkFees.gte(zkInteropFee), "coinbase should accumulate the fixed ZK fee").to.be.true;

    const recipientBefore = await getNativeBalance(destProvider, dummyRecipient1);
    const receipt = await executeBundle(destProvider, sendResult.bundleData, sourceChainId);
    expect(receipt.status, "single direct call fixed fee: executeBundle tx should succeed").to.equal(1);

    const recipientAfter = await getNativeBalance(destProvider, dummyRecipient1);
    expectBalanceDelta(recipientBefore, recipientAfter, amount, "single direct call fixed fee: recipient native");
  });

  it("can send and execute a single indirect call bundle", async () => {
    const tokenAmount = randomBigNumber(ERC20_TOKEN_MIN, ERC20_TOKEN_MAX);
    const interopFee = await currentInteropFee();
    const msgValue = interopFee;

    await approveTokenForNtv(sourceProvider, sourceTokenAddress, tokenAmount);

    const callStarters: CallStarter[] = [
      {
        to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
        data: getTokenTransferData(sourceAssetId, tokenAmount, getInteropRecipientAddress()),
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
    const recipientTokenBefore = await getTokenBalance(destProvider, destTokenAddress, getInteropRecipientAddress());

    const receipt = await executeBundle(destProvider, sendResult.bundleData, sourceChainId);

    expect(receipt.status, "single indirect call: executeBundle tx should succeed").to.equal(1);

    // Re-resolve token address (NTV may have deployed the bridged token during executeBundle)
    destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);

    const recipientTokenAfter = await getTokenBalance(destProvider, destTokenAddress, getInteropRecipientAddress());
    expectBalanceDelta(recipientTokenBefore, recipientTokenAfter, tokenAmount, "single indirect call: recipient token");

    console.log("   [receive] Single indirect call bundle executed");
  });

  it("can send and execute a two direct call bundle", async () => {
    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const interopFee = await currentInteropFee();
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

    const bundleAttributes = [executionAddressAttr(getInteropSourceAddress())];

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
    const interopFee = await currentInteropFee();
    const msgValue = interopFee.mul(2);

    await approveTokenForNtv(sourceProvider, sourceTokenAddress, totalTokenAmount);

    const callStarters: CallStarter[] = [
      {
        to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
        data: getTokenTransferData(sourceAssetId, tokenAmount, getInteropRecipientAddress()),
        callAttributes: [indirectCallAttr()],
      },
      {
        to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
        data: getTokenTransferData(sourceAssetId, tokenAmount, getInteropSecondaryRecipientAddress()),
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
    const recipient1TokenBefore = await getTokenBalance(destProvider, destTokenAddress, getInteropRecipientAddress());
    const recipient2TokenBefore = await getTokenBalance(
      destProvider,
      destTokenAddress,
      getInteropSecondaryRecipientAddress()
    );

    const receipt = await executeBundle(destProvider, sendResult.bundleData, sourceChainId);

    expect(receipt.status, "two indirect calls: executeBundle tx should succeed").to.equal(1);

    destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);
    const recipient1TokenAfter = await getTokenBalance(destProvider, destTokenAddress, getInteropRecipientAddress());
    const recipient2TokenAfter = await getTokenBalance(
      destProvider,
      destTokenAddress,
      getInteropSecondaryRecipientAddress()
    );

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
    const interopFee = await currentInteropFee();
    const msgValue = interopFee.mul(2).add(valueAmount);

    await approveTokenForNtv(sourceProvider, sourceTokenAddress, tokenAmount);

    const callStarters: CallStarter[] = [
      {
        to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
        data: getTokenTransferData(sourceAssetId, tokenAmount, getInteropRecipientAddress()),
        callAttributes: [indirectCallAttr()],
      },
      {
        to: encodeEvmAddress(dummyRecipient2),
        data: "0x",
        callAttributes: [interopCallValueAttr(valueAmount)],
      },
    ];

    const bundleAttributes = [executionAddressAttr(getInteropSourceAddress())];

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
    const recipientTokenBefore = await getTokenBalance(destProvider, destTokenAddress, getInteropRecipientAddress());
    const recipient2NativeBefore = await getNativeBalance(destProvider, dummyRecipient2);

    const receipt = await executeBundle(destProvider, sendResult.bundleData, sourceChainId);

    expect(receipt.status, "mixed bundle: executeBundle tx should succeed").to.equal(1);

    destTokenAddress = await getTokenAddressForAsset(destProvider, sourceAssetId);
    const recipientTokenAfter = await getTokenBalance(destProvider, destTokenAddress, getInteropRecipientAddress());
    const recipient2NativeAfter = await getNativeBalance(destProvider, dummyRecipient2);

    expectBalanceDelta(recipientTokenBefore, recipientTokenAfter, tokenAmount, "mixed bundle: recipient token");
    expectBalanceDelta(recipient2NativeBefore, recipient2NativeAfter, valueAmount, "mixed bundle: recipient2 native");

    console.log("   [receive] Mixed bundle executed");
  });

  // ─── Edge cases ──────────────────────────────────────────────

  it("cannot execute the same bundle twice (replay protection)", async () => {
    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const interopFee = await currentInteropFee();
    const msgValue = interopFee.add(amount);

    const callStarters: CallStarter[] = [
      {
        to: encodeEvmAddress(dummyRecipient1),
        data: "0x",
        callAttributes: [interopCallValueAttr(amount)],
      },
    ];

    const bundleAttributes = [executionAddressAttr(getInteropSourceAddress())];

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
    await expectRevert(
      () => simulateExecuteBundle(destProvider, sendResult.bundleData, sourceChainId),
      "replay executeBundle",
      customError("InteropHandler", "BundleAlreadyProcessed(bytes32)"),
      destProvider
    );

    console.log("   [edge] Replay protection verified");
  });

  it("cannot execute a bundle from a non-matching executionAddress", async () => {
    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const interopFee = await currentInteropFee();
    const msgValue = interopFee.add(amount);

    const callStarters: CallStarter[] = [
      {
        to: encodeEvmAddress(dummyRecipient1),
        data: "0x",
        callAttributes: [interopCallValueAttr(amount)],
      },
    ];

    // Set executionAddress to a signer other than the default test signer.
    const bundleAttributes = [executionAddressAttr(getInteropSecondaryRecipientAddress())];

    const sendResult = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters,
      bundleAttributes,
      value: msgValue,
    });

    // Attempt to execute from the default account (which is NOT the executionAddress)
    await expectRevert(
      () => simulateExecuteBundle(destProvider, sendResult.bundleData, sourceChainId),
      "execute from wrong executionAddress",
      customError("InteropHandler", "ExecutingNotAllowed(bytes32,bytes,bytes)"),
      destProvider
    );

    console.log("   [edge] executionAddress enforcement verified");
  });

  it("accepts a bundle with zero calls", async () => {
    // The protocol allows empty bundles — they can be sent, verified, and executed.
    const bundleAttributes = [executionAddressAttr(getInteropSourceAddress())];

    const sendResult = await sendInteropBundle({
      sourceProvider,
      destinationChainId: destChainId,
      callStarters: [],
      bundleAttributes,
      value: ethers.BigNumber.from(0),
    });

    expect(sendResult.txHash).to.not.be.null;

    const receipt = await executeBundle(destProvider, sendResult.bundleData, sourceChainId);
    expect(receipt.status).to.equal(1);

    console.log("   [edge] Zero-call bundle accepted and executed");
  });

  it("rejects a bundle with excess msg.value", async () => {
    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const interopFee = await currentInteropFee();
    const correctValue = interopFee.add(amount);
    const excessValue = correctValue.add(EXCESS_MSG_VALUE_DELTA);

    const callStarters: CallStarter[] = [
      {
        to: encodeEvmAddress(dummyRecipient1),
        data: "0x",
        callAttributes: [interopCallValueAttr(amount)],
      },
    ];

    const bundleAttributes = [executionAddressAttr(getInteropSourceAddress())];

    await expectRevert(
      () =>
        simulateInteropBundle({
          sourceProvider,
          destinationChainId: destChainId,
          callStarters,
          bundleAttributes,
          value: excessValue,
        }),
      "excess msg.value",
      customError("InteropCenter", "MsgValueMismatch(uint256,uint256)"),
      sourceProvider
    );

    console.log("   [edge] Excess msg.value rejected");
  });

  it("can migrate a chain-A-native token to Gateway and round-trip it over interop", async function () {
    const chainAToken = await deployL2NativeToken({
      provider: sourceProvider,
      chainId: sourceChainId,
      name: "Live Interop Chain A Native Token",
      symbol: "LIA",
    });
    const chainAAssetId = await migrateTokenToGateway({
      chainId: sourceChainId,
      l2RpcUrl: sourceProvider.connection.url,
      tokenAddress: chainAToken,
      l1RpcUrl,
      l1Provider,
      gwRpcUrl: gatewayRpcUrl,
      l1NativeTokenVaultAddr: state.l1Addresses!.l1NativeTokenVault,
      l1AssetTrackerAddr: state.l1Addresses!.l1AssetTracker,
      chainAddresses: state.chainAddresses!,
      gatewayChainId,
    });
    expect(chainAAssetId, "chain A native token assetId").to.equal(encodeNtvAssetId(sourceChainId, chainAToken));

    const chainBToken = await sendAndExecuteTokenInterop({
      sendProvider: sourceProvider,
      receiveProvider: destProvider,
      sourceChainId,
      destinationChainId: destChainId,
      sourceTokenAddress: chainAToken,
      assetId: chainAAssetId,
      amount: ROUNDTRIP_TOKEN_TRANSFER_AMOUNT,
      recipientAddress: getInteropSourceAddress(),
      label: "chain A native token A->B interop",
    });

    await sendAndExecuteTokenInterop({
      sendProvider: destProvider,
      receiveProvider: sourceProvider,
      sourceChainId: destChainId,
      destinationChainId: sourceChainId,
      sourceTokenAddress: chainBToken,
      assetId: chainAAssetId,
      amount: ROUNDTRIP_TOKEN_TRANSFER_AMOUNT,
      recipientAddress: getInteropSourceAddress(),
      label: "chain A native token B->A interop",
    });

    console.log("   [roundtrip] Chain-A-native token migrated to Gateway and round-tripped over interop");
  });
});
