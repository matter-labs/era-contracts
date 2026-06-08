import { expect } from "chai";
import type { BigNumber } from "ethers";
import { ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole, getL2Chain } from "../../src/core/utils";
import { encodeNtvAssetId } from "../../src/core/data-encoding";
import { getInteropRecipientAddress, getInteropSourceAddress } from "../../src/core/accounts";
import { ETH_TOKEN_ADDRESS, INTEROP_CENTER_ADDR, L1_CHAIN_ID, L2_ASSET_ROUTER_ADDR } from "../../src/core/const";
import { encodeEvmChainAddress } from "../../src/helpers/erc7930";
import {
  sendInteropMessage,
  executeBundle,
  interopCallValueAttr,
  indirectCallAttr,
  useFixedFeeAttr,
  getTokenTransferData,
  getInteropProtocolFee,
  getZkInteropFee,
  getZkTokenAssetId,
  getZkTokenAddress,
  deployDummyInteropRecipient,
} from "../../src/helpers/interop-helpers";
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
  randomBigNumber,
} from "../../src/helpers/balance-helpers";

/**
 * 08 - Interop Messages (sendMessage / executeBundle)
 *
 * Tests InteropCenter.sendMessage() for cross-chain value transfers
 * (base token and ERC20) and verifies that executeBundle on the destination
 * chain delivers the correct balances.
 *
 * Topology: gwSettledChainIds[0] = source, gwSettledChainIds[1] = destination
 */
describe("08 - Interop Messages (GW-settled chains)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let gwSettledChainIds: number[];

  // Chain providers
  let sourceProvider: ethers.providers.JsonRpcProvider;
  let destProvider: ethers.providers.JsonRpcProvider;
  let sourceChainId: number;
  let destChainId: number;

  // The interop protocol fee (paid in base token on each sendMessage)
  let interopFee: BigNumber;

  // The test ERC20 token native to the source chain
  let sourceTokenAddress: string;
  let sourceAssetId: string;
  let sourceZkTokenAddress: string;
  let zkInteropFee: BigNumber;
  let fixedZkFeeTestsEnabled = false;

  // Randomized per-test amount ranges
  const BASE_TOKEN_MIN = ethers.utils.parseUnits("100", "gwei");
  const BASE_TOKEN_MAX = ethers.utils.parseUnits("10000", "gwei");
  const ERC20_MIN = ethers.utils.parseUnits("1", 18);
  const ERC20_MAX = ethers.utils.parseUnits("100", 18);

  // Chain with a custom (non-ETH) base token for cross-base-token tests
  let customBaseTokenChainId: number | undefined;
  let customBaseTokenProvider: ethers.providers.JsonRpcProvider | undefined;

  // DummyInteropRecipient on dest chain for base token (direct call) messages
  let dummyRecipient: string;

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
      throw new Error("At least 2 GW-settled chains required for interop message tests");
    }

    sourceChainId = gwSettledChainIds[0];
    destChainId = gwSettledChainIds[1];

    const sourceChain = getL2Chain(state.chains, sourceChainId);
    const destChain = getL2Chain(state.chains, destChainId);
    sourceProvider = new ethers.providers.JsonRpcProvider(sourceChain.rpcUrl);
    destProvider = new ethers.providers.JsonRpcProvider(destChain.rpcUrl);

    interopFee = await getInteropProtocolFee(sourceProvider);
    zkInteropFee = await getZkInteropFee(sourceProvider);
    console.log(`   Interop protocol fee: ${interopFee.toString()}`);
    console.log(`   Fixed ZK interop fee: ${zkInteropFee.toString()}`);

    sourceTokenAddress = state.testTokens[sourceChainId];
    sourceAssetId = await getAssetIdForToken(sourceProvider, sourceTokenAddress);
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

    // Deploy DummyInteropRecipient on destination chain for direct-call messages
    dummyRecipient = await deployDummyInteropRecipient(destProvider);
    console.log(`   DummyInteropRecipient: ${dummyRecipient}`);
    console.log(`   Source test token: ${sourceTokenAddress} (chain ${sourceChainId})`);
    console.log(`   Source test token assetId: ${sourceAssetId}`);

    // Find a GW-settled chain with a custom (non-ETH) base token for cross-base-token tests
    const customBaseTokenConfig = state.chains!.config.find(
      (c) => c.role === "gwSettled" && c.baseToken && c.baseToken !== ETH_TOKEN_ADDRESS
    );
    if (customBaseTokenConfig) {
      customBaseTokenChainId = customBaseTokenConfig.chainId;
      const customChain = getL2Chain(state.chains!, customBaseTokenChainId);
      customBaseTokenProvider = new ethers.providers.JsonRpcProvider(customChain.rpcUrl);
      console.log(`   Custom base token chain: ${customBaseTokenChainId}`);
    }
  });

  it("can send and receive a base token message (direct call with value)", async function () {
    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const interopFee = await currentInteropFee();
    const recipient = encodeEvmChainAddress(dummyRecipient, destChainId);
    const payload = "0x";
    const attributes = [interopCallValueAttr(amount)];
    const msgValue = interopFee.add(amount);

    const balBefore = await captureBalance(sourceProvider);

    const result = await sendInteropMessage({
      sourceProvider,
      recipient,
      payload,
      attributes,
      value: msgValue,
    });

    expect(result.txHash).to.be.a("string").and.not.equal("");
    expect(result.interopBundle).to.not.be.null;

    const balAfter = await captureBalance(sourceProvider);
    expectNativeSpend(balBefore, balAfter, msgValue, result.receipt, "base token message");

    console.log(`   Base token message sent: ${result.txHash}`);

    // ── Execute on destination ──
    const recipientBalBefore = await getNativeBalance(destProvider, dummyRecipient);

    const receipt = await executeBundle(destProvider, result.bundleData, sourceChainId);
    expect(receipt.status).to.equal(1);

    const recipientBalAfter = await getNativeBalance(destProvider, dummyRecipient);
    expectBalanceDelta(recipientBalBefore, recipientBalAfter, amount, "base token message: recipient native");

    const balDelta = recipientBalAfter.sub(recipientBalBefore);
    console.log(`   Base token received on destination: +${ethers.utils.formatEther(balDelta)} ETH`);
  });

  it("can send and receive a base token message with fixed ZK fees", async function () {
    if (!fixedZkFeeTestsEnabled) {
      this.skip();
    }

    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const recipient = encodeEvmChainAddress(dummyRecipient, destChainId);
    const payload = "0x";
    const attributes = [interopCallValueAttr(amount), useFixedFeeAttr(true)];

    const zkBalance = await getTokenBalance(sourceProvider, sourceZkTokenAddress, getInteropSourceAddress());
    expect(
      zkBalance.gte(zkInteropFee),
      `fixed-fee base token message: sender ZK token balance ${zkBalance.toString()} is below required fee ${zkInteropFee.toString()}`
    ).to.be.true;

    await approveToken(sourceProvider, sourceZkTokenAddress, INTEROP_CENTER_ADDR, zkInteropFee);

    const balBefore = await captureBalance(sourceProvider, sourceZkTokenAddress);
    const result = await sendInteropMessage({
      sourceProvider,
      recipient,
      payload,
      attributes,
      value: amount,
    });
    const balAfter = await captureBalance(sourceProvider, sourceZkTokenAddress);

    expectNativeSpend(balBefore, balAfter, amount, result.receipt, "fixed-fee base token message");
    expect(
      balAfter.token!.eq(balBefore.token!.sub(zkInteropFee)),
      "fixed-fee base token message: sender ZK token should decrease by the fixed fee"
    ).to.be.true;

    const recipientBalBefore = await getNativeBalance(destProvider, dummyRecipient);
    const receipt = await executeBundle(destProvider, result.bundleData, sourceChainId);
    expect(receipt.status).to.equal(1);

    const recipientBalAfter = await getNativeBalance(destProvider, dummyRecipient);
    expectBalanceDelta(recipientBalBefore, recipientBalAfter, amount, "fixed-fee base token message: recipient native");
  });

  it("can send and receive a native ERC20 token message (indirect call via AssetRouter)", async function () {
    const erc20Amount = randomBigNumber(ERC20_MIN, ERC20_MAX);
    const interopFee = await currentInteropFee();
    const recipient = encodeEvmChainAddress(L2_ASSET_ROUTER_ADDR, destChainId);
    const payload = getTokenTransferData(sourceAssetId, erc20Amount, getInteropRecipientAddress());
    const attributes = [indirectCallAttr()];
    const msgValue = interopFee;

    // Approve NTV to spend tokens before sending
    await approveTokenForNtv(sourceProvider, sourceTokenAddress, erc20Amount);

    const balBefore = await captureBalance(sourceProvider, sourceTokenAddress);

    const result = await sendInteropMessage({
      sourceProvider,
      recipient,
      payload,
      attributes,
      value: msgValue,
    });

    expect(result.txHash).to.be.a("string").and.not.equal("");
    expect(result.interopBundle).to.not.be.null;

    const balAfter = await captureBalance(sourceProvider, sourceTokenAddress);

    // Token balance should decrease by exactly erc20Amount
    expect(
      balAfter.token!.eq(balBefore.token!.sub(erc20Amount)),
      "ERC20 message: sender token should decrease by erc20Amount"
    ).to.be.true;

    expectNativeSpend(balBefore, balAfter, msgValue, result.receipt, "ERC20 message");

    console.log(`   Native ERC20 message sent: ${result.txHash}`);

    // ── Execute on destination ──
    // Resolve the token address on the destination chain for the source chain's token
    let destTokenAddr = await getTokenAddressForAsset(destProvider, sourceAssetId);

    const recipientBalBefore = await getTokenBalance(destProvider, destTokenAddr, getInteropRecipientAddress());

    const receipt = await executeBundle(destProvider, result.bundleData, sourceChainId);
    expect(receipt.status).to.equal(1);

    // Re-resolve: NTV may have deployed the bridged token during executeBundle
    destTokenAddr = await getTokenAddressForAsset(destProvider, sourceAssetId);

    const recipientBalAfter = await getTokenBalance(destProvider, destTokenAddr, getInteropRecipientAddress());
    expectBalanceDelta(recipientBalBefore, recipientBalAfter, erc20Amount, "ERC20 message: recipient token");

    const balDelta = recipientBalAfter.sub(recipientBalBefore);
    console.log(
      `   Native ERC20 received on destination: +${ethers.utils.formatUnits(balDelta, 18)} tokens at ${destTokenAddr}`
    );
  });

  it("can send and receive base token to a chain with a different base token (indirect via AssetRouter)", async function () {
    if (!customBaseTokenChainId) {
      this.skip();
      return;
    }

    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);
    const interopFee = await currentInteropFee();
    const ethAssetId = encodeNtvAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
    const recipient = encodeEvmChainAddress(L2_ASSET_ROUTER_ADDR, customBaseTokenChainId);
    const payload = getTokenTransferData(ethAssetId, amount, getInteropRecipientAddress());
    // callValue = amount because ETH is the sender's base token (native),
    // so the AssetRouter receives it via msg.value rather than ERC20 transferFrom.
    const attributes = [indirectCallAttr(amount)];
    const msgValue = interopFee.add(amount);

    const balBefore = await captureBalance(sourceProvider);

    const result = await sendInteropMessage({
      sourceProvider,
      recipient,
      payload,
      attributes,
      value: msgValue,
    });

    expect(result.txHash).to.be.a("string").and.not.equal("");
    expect(result.interopBundle).to.not.be.null;

    const balAfter = await captureBalance(sourceProvider);
    expectNativeSpend(balBefore, balAfter, msgValue, result.receipt, "cross-base-token message");

    console.log(`   Cross-base-token message sent: ${result.txHash}`);

    // ── Execute on destination ──
    // Resolve bridged ETH addr (may be zero if not yet deployed — NTV deploys during execute)
    let bridgedEthAddr = await getTokenAddressForAsset(customBaseTokenProvider!, ethAssetId);
    const recipientBalBefore =
      bridgedEthAddr !== ethers.constants.AddressZero
        ? await getTokenBalance(customBaseTokenProvider!, bridgedEthAddr, getInteropRecipientAddress())
        : ethers.BigNumber.from(0);

    const receipt = await executeBundle(customBaseTokenProvider!, result.bundleData, sourceChainId);
    expect(receipt.status).to.equal(1);

    // Re-resolve after execution (NTV may have deployed the bridged token)
    bridgedEthAddr = await getTokenAddressForAsset(customBaseTokenProvider!, ethAssetId);
    expect(bridgedEthAddr).to.not.equal(ethers.constants.AddressZero, "bridged ETH token should be deployed");

    const recipientBalAfter = await getTokenBalance(
      customBaseTokenProvider!,
      bridgedEthAddr,
      getInteropRecipientAddress()
    );
    expectBalanceDelta(recipientBalBefore, recipientBalAfter, amount, "cross-base-token: recipient bridged ETH");

    const balDelta = recipientBalAfter.sub(recipientBalBefore);
    console.log(
      `   Cross-base-token received: +${ethers.utils.formatEther(balDelta)} bridged ETH at ${bridgedEthAddr}`
    );
  });

  it("can send custom base token from a custom-base-token chain to an ETH chain (custom → era)", async function () {
    // Reverse of the era → custom test above: send the custom base token FROM chain 14
    // TO an ETH-based chain. On the destination (ETH) chain, the custom base token
    // arrives as a bridged ERC20 via the AssetRouter.
    if (!customBaseTokenChainId || !customBaseTokenProvider) {
      this.skip();
      return;
    }

    // The custom base token's L1 address — needed to compute its assetId
    const customBaseTokenL1Addr = state.customBaseTokens?.[customBaseTokenChainId];
    if (!customBaseTokenL1Addr) {
      console.log("   Custom base token L1 address not found in state; skipping");
      this.skip();
      return;
    }

    const customBaseTokenAssetId = encodeNtvAssetId(L1_CHAIN_ID, customBaseTokenL1Addr);
    const amount = randomBigNumber(BASE_TOKEN_MIN, BASE_TOKEN_MAX);

    // Send from chain 14 → destChainId (ETH chain). The custom base token is native on
    // chain 14, so the AssetRouter receives it via msg.value (indirectCall with callValue).
    const customChainInteropFee = await getInteropProtocolFee(customBaseTokenProvider);
    const recipient = encodeEvmChainAddress(L2_ASSET_ROUTER_ADDR, destChainId);
    const payload = getTokenTransferData(customBaseTokenAssetId, amount, getInteropRecipientAddress());
    const attributes = [indirectCallAttr(amount)];
    const msgValue = customChainInteropFee.add(amount);

    const result = await sendInteropMessage({
      sourceProvider: customBaseTokenProvider,
      recipient,
      payload,
      attributes,
      value: msgValue,
    });

    expect(result.txHash).to.be.a("string").and.not.equal("");
    expect(result.interopBundle).to.not.be.null;

    console.log(`   Custom→ERA message sent: ${result.txHash}`);

    // ── Execute on destination (ETH chain) ──
    let bridgedTokenAddr = await getTokenAddressForAsset(destProvider, customBaseTokenAssetId);
    const recipientBalBefore =
      bridgedTokenAddr !== ethers.constants.AddressZero
        ? await getTokenBalance(destProvider, bridgedTokenAddr, getInteropRecipientAddress())
        : ethers.BigNumber.from(0);

    const receipt = await executeBundle(destProvider, result.bundleData, customBaseTokenChainId);
    expect(receipt.status).to.equal(1);

    bridgedTokenAddr = await getTokenAddressForAsset(destProvider, customBaseTokenAssetId);
    expect(bridgedTokenAddr).to.not.equal(ethers.constants.AddressZero, "bridged custom token should be deployed");

    const recipientBalAfter = await getTokenBalance(destProvider, bridgedTokenAddr, getInteropRecipientAddress());
    expectBalanceDelta(recipientBalBefore, recipientBalAfter, amount, "custom→era: recipient bridged token");

    const balDelta = recipientBalAfter.sub(recipientBalBefore);
    console.log(
      `   Custom→ERA received: +${ethers.utils.formatEther(balDelta)} bridged custom token at ${bridgedTokenAddr}`
    );
  });

  it("can send and receive a bridged ERC20 token message (indirect call via AssetRouter)", async function () {
    const destTestToken = state.testTokens![destChainId];
    if (!destTestToken) {
      console.log("   Destination test token not configured; skipping bridged ERC20 token message");
      this.skip();
      return;
    }

    const bridgedAssetId = await getAssetIdForToken(destProvider, destTestToken);

    // Resolve the bridged token address on the source chain
    const bridgedTokenOnSource = await getTokenAddressForAsset(sourceProvider, bridgedAssetId);

    if (bridgedTokenOnSource === ethers.constants.AddressZero) {
      console.log(
        "   Bridged token not yet deployed on source chain; skipping" +
          " (requires a prior reverse-direction transfer to deploy the bridged representation)"
      );
      this.skip();
      return;
    }

    const bridgedAmount = ethers.utils.parseUnits("2", 18);
    const bridgedBalance = await getTokenBalance(sourceProvider, bridgedTokenOnSource, getInteropSourceAddress());

    if (bridgedBalance.lt(bridgedAmount)) {
      console.log(`   Insufficient bridged token balance: have ${bridgedBalance}, need ${bridgedAmount}; skipping`);
      this.skip();
      return;
    }

    const recipient = encodeEvmChainAddress(L2_ASSET_ROUTER_ADDR, destChainId);
    const payload = getTokenTransferData(bridgedAssetId, bridgedAmount, getInteropRecipientAddress());
    const attributes = [indirectCallAttr()];
    const interopFee = await currentInteropFee();
    const msgValue = interopFee;

    await approveTokenForNtv(sourceProvider, bridgedTokenOnSource, bridgedAmount);

    const balBefore = await getTokenBalance(sourceProvider, bridgedTokenOnSource, getInteropSourceAddress());

    const result = await sendInteropMessage({
      sourceProvider,
      recipient,
      payload,
      attributes,
      value: msgValue,
    });

    expect(result.txHash).to.be.a("string").and.not.equal("");
    expect(result.interopBundle).to.not.be.null;

    const balAfter = await getTokenBalance(sourceProvider, bridgedTokenOnSource, getInteropSourceAddress());
    expect(
      balAfter.eq(balBefore.sub(bridgedAmount)),
      "bridged ERC20 message: sender token should decrease by bridgedAmount"
    ).to.be.true;

    console.log(`   Bridged ERC20 message sent: ${result.txHash}`);

    // ── Execute on destination ──
    const destTokenAddr = await getTokenAddressForAsset(destProvider, bridgedAssetId);

    const recipientBalBefore = await getTokenBalance(destProvider, destTokenAddr, getInteropRecipientAddress());

    const receipt = await executeBundle(destProvider, result.bundleData, sourceChainId);
    expect(receipt.status).to.equal(1);

    const recipientBalAfter = await getTokenBalance(destProvider, destTokenAddr, getInteropRecipientAddress());
    expectBalanceDelta(recipientBalBefore, recipientBalAfter, bridgedAmount, "bridged ERC20 message: recipient token");

    const balDelta = recipientBalAfter.sub(recipientBalBefore);
    console.log(
      `   Bridged ERC20 received on destination: +${ethers.utils.formatUnits(balDelta, 18)} tokens at ${destTokenAddr}`
    );
  });
});
