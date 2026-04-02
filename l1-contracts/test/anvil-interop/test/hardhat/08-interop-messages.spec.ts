import { expect } from "chai";
import type { BigNumber } from "ethers";
import { ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getChainIdsByRole, getL2Chain } from "../../src/core/utils";
import { encodeNtvAssetId } from "../../src/core/data-encoding";
import { ANVIL_DEFAULT_ACCOUNT_ADDR, ANVIL_RECIPIENT_ADDR, L2_ASSET_ROUTER_ADDR } from "../../src/core/const";
import {
  sendInteropMessage,
  executeBundle,
  encodeEvmChainAddress,
  interopCallValueAttr,
  indirectCallAttr,
  getTokenTransferData,
  captureSourceBalance,
  getNativeBalance,
  getTokenBalance,
  getTokenAddressForAsset,
  approveAndReturnAmount,
  getInteropProtocolFee,
  deployDummyInteropRecipient,
} from "../../src/helpers/interop-bundle-helper";

/**
 * 08 - Interop Messages (sendMessage / executeBundle)
 *
 * Ports the interop-b-messages tests from zksync-era to the Anvil multichain
 * harness. Tests InteropCenter.sendMessage() for cross-chain value transfers
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
  let sourceTestToken: string;
  let sourceTestTokenAssetId: string;

  // Amount constants
  const BASE_TOKEN_AMOUNT = ethers.utils.parseEther("1");
  const ERC20_AMOUNT = ethers.utils.parseUnits("10", 18);

  // Saved bundle data from send tests, consumed by corresponding receive tests
  let baseTokenBundleData: string;
  let baseTokenSourceChainId: number;
  let nativeErc20BundleData: string;
  let nativeErc20SourceChainId: number;
  let bridgedErc20BundleData: string;
  let bridgedErc20SourceChainId: number;

  // DummyInteropRecipient on dest chain for base token (direct call) messages
  let dummyRecipient: string;

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
    console.log(`   Interop protocol fee: ${ethers.utils.formatEther(interopFee)} ETH`);

    sourceTestToken = state.testTokens[sourceChainId];
    sourceTestTokenAssetId = encodeNtvAssetId(sourceChainId, sourceTestToken);

    // Deploy DummyInteropRecipient on destination chain for direct-call messages
    dummyRecipient = await deployDummyInteropRecipient(destProvider);
    console.log(`   DummyInteropRecipient: ${dummyRecipient}`);
    console.log(`   Source test token: ${sourceTestToken} (chain ${sourceChainId})`);
    console.log(`   Source test token assetId: ${sourceTestTokenAssetId}`);
  });

  // ── Sending messages ──────────────────────────────────────────

  describe("Can send cross chain messages", function () {
    it("sends a base token message (direct call with value)", async function () {
      const recipient = encodeEvmChainAddress(dummyRecipient, destChainId);
      const payload = "0x";
      const attributes = [interopCallValueAttr(BASE_TOKEN_AMOUNT)];
      const msgValue = interopFee.add(BASE_TOKEN_AMOUNT);

      const balBefore = await captureSourceBalance(sourceProvider);

      const result = await sendInteropMessage({
        sourceProvider,
        recipient,
        payload,
        attributes,
        value: msgValue,
      });

      expect(result.txHash).to.be.a("string").and.not.equal("");
      expect(result.interopBundle).to.not.be.null;

      const balAfter = await captureSourceBalance(sourceProvider);
      const nativeDelta = balBefore.native.sub(balAfter.native);
      // Native balance should decrease by at least msgValue (+ gas)
      expect(nativeDelta.gte(msgValue), `native balance should decrease by at least ${msgValue}, got ${nativeDelta}`).to
        .be.true;

      baseTokenBundleData = result.bundleData;
      baseTokenSourceChainId = sourceChainId;

      console.log(`   Base token message sent: ${result.txHash}`);
    });

    it("sends a native ERC20 token message (indirect call via AssetRouter)", async function () {
      const recipient = encodeEvmChainAddress(L2_ASSET_ROUTER_ADDR, destChainId);
      const payload = getTokenTransferData(sourceTestTokenAssetId, ERC20_AMOUNT, ANVIL_RECIPIENT_ADDR);
      const attributes = [indirectCallAttr()];
      const msgValue = interopFee;

      // Approve NTV to spend tokens before sending
      await approveAndReturnAmount(sourceProvider, sourceTestToken, ERC20_AMOUNT);

      const balBefore = await captureSourceBalance(sourceProvider, sourceTestToken);

      const result = await sendInteropMessage({
        sourceProvider,
        recipient,
        payload,
        attributes,
        value: msgValue,
      });

      expect(result.txHash).to.be.a("string").and.not.equal("");
      expect(result.interopBundle).to.not.be.null;

      const balAfter = await captureSourceBalance(sourceProvider, sourceTestToken);

      // Token balance should decrease by exactly ERC20_AMOUNT
      const tokenDelta = balBefore.token!.sub(balAfter.token!);
      expect(tokenDelta.eq(ERC20_AMOUNT), `token balance should decrease by ${ERC20_AMOUNT}, got ${tokenDelta}`).to.be
        .true;

      // Native balance should decrease by at least the fee (+ gas)
      const nativeDelta = balBefore.native.sub(balAfter.native);
      expect(nativeDelta.gte(msgValue), `native balance should decrease by at least ${msgValue}, got ${nativeDelta}`).to
        .be.true;

      nativeErc20BundleData = result.bundleData;
      nativeErc20SourceChainId = sourceChainId;

      console.log(`   Native ERC20 message sent: ${result.txHash}`);
    });

    it.skip("sends base token from a chain with a different base token (skipped: Anvil chains share ETH base token)", function () {
      // All Anvil test chains use ETH as the base token, so the
      // isSameBaseToken path is always true. This scenario requires a
      // chain with a non-ETH base token, which is not configured in the
      // current Anvil harness.
    });

    it("sends a bridged ERC20 token message (indirect call via AssetRouter)", async function () {
      // A "bridged" token in the source test is one that was deployed on a
      // different chain and bridged to the source. In the Anvil harness, the
      // destination chain's test token serves this role: its assetId
      // references destChainId, and it may already have been bridged to the
      // source chain via a prior interop transfer (spec 06).
      //
      // We use the destination chain's test token assetId. If the token
      // does not yet exist on the source chain (no prior transfer created
      // the bridged representation), the NTV will deploy it during the
      // sendMessage flow.
      //
      // The underlying contract path (L2NativeTokenVault.bridgeBurn →
      // AssetRouter) is identical to the native ERC20 case; only the
      // assetId differs (pointing to destChainId rather than sourceChainId).

      const destTestToken = state.testTokens![destChainId];
      const bridgedAssetId = encodeNtvAssetId(destChainId, destTestToken);

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
      const bridgedBalance = await getTokenBalance(sourceProvider, bridgedTokenOnSource, ANVIL_DEFAULT_ACCOUNT_ADDR);

      if (bridgedBalance.lt(bridgedAmount)) {
        console.log(`   Insufficient bridged token balance: have ${bridgedBalance}, need ${bridgedAmount}; skipping`);
        this.skip();
        return;
      }

      const recipient = encodeEvmChainAddress(L2_ASSET_ROUTER_ADDR, destChainId);
      const payload = getTokenTransferData(bridgedAssetId, bridgedAmount, ANVIL_RECIPIENT_ADDR);
      const attributes = [indirectCallAttr()];
      const msgValue = interopFee;

      await approveAndReturnAmount(sourceProvider, bridgedTokenOnSource, bridgedAmount);

      const balBefore = await getTokenBalance(sourceProvider, bridgedTokenOnSource, ANVIL_DEFAULT_ACCOUNT_ADDR);

      const result = await sendInteropMessage({
        sourceProvider,
        recipient,
        payload,
        attributes,
        value: msgValue,
      });

      expect(result.txHash).to.be.a("string").and.not.equal("");
      expect(result.interopBundle).to.not.be.null;

      const balAfter = await getTokenBalance(sourceProvider, bridgedTokenOnSource, ANVIL_DEFAULT_ACCOUNT_ADDR);
      const tokenDelta = balBefore.sub(balAfter);
      expect(
        tokenDelta.eq(bridgedAmount),
        `bridged token balance should decrease by ${bridgedAmount}, got ${tokenDelta}`
      ).to.be.true;

      bridgedErc20BundleData = result.bundleData;
      bridgedErc20SourceChainId = sourceChainId;

      console.log(`   Bridged ERC20 message sent: ${result.txHash}`);
    });
  });

  // ── Receiving messages ─────────────────────────────────────────

  describe("Can receive cross chain messages", function () {
    it("receives a message sending a base token", async function () {
      if (!baseTokenBundleData) {
        this.skip();
        return;
      }

      const recipientBalBefore = await getNativeBalance(destProvider, dummyRecipient);

      const receipt = await executeBundle(destProvider, baseTokenBundleData, baseTokenSourceChainId);
      expect(receipt.status).to.equal(1);

      const recipientBalAfter = await getNativeBalance(destProvider, dummyRecipient);
      const balDelta = recipientBalAfter.sub(recipientBalBefore);
      expect(
        balDelta.eq(BASE_TOKEN_AMOUNT),
        `recipient native balance should increase by ${BASE_TOKEN_AMOUNT}, got ${balDelta}`
      ).to.be.true;

      console.log(`   Base token received on destination: +${ethers.utils.formatEther(balDelta)} ETH`);
    });

    it("receives a message sending a native ERC20 token", async function () {
      if (!nativeErc20BundleData) {
        this.skip();
        return;
      }

      // Resolve the token address on the destination chain for the source chain's token
      let destTokenAddr = await getTokenAddressForAsset(destProvider, sourceTestTokenAssetId);

      const recipientBalBefore = await getTokenBalance(destProvider, destTokenAddr, ANVIL_RECIPIENT_ADDR);

      const receipt = await executeBundle(destProvider, nativeErc20BundleData, nativeErc20SourceChainId);
      expect(receipt.status).to.equal(1);

      // Re-resolve: NTV may have deployed the bridged token during executeBundle
      destTokenAddr = await getTokenAddressForAsset(destProvider, sourceTestTokenAssetId);

      const recipientBalAfter = await getTokenBalance(destProvider, destTokenAddr, ANVIL_RECIPIENT_ADDR);
      const balDelta = recipientBalAfter.sub(recipientBalBefore);
      expect(balDelta.eq(ERC20_AMOUNT), `recipient ERC20 balance should increase by ${ERC20_AMOUNT}, got ${balDelta}`)
        .to.be.true;

      console.log(
        `   Native ERC20 received on destination: +${ethers.utils.formatUnits(balDelta, 18)} tokens at ${destTokenAddr}`
      );
    });

    it.skip("receives a message sending the base token from the sending chain (skipped: Anvil chains share ETH base token)", function () {
      // Corresponds to the "interop1 base token" send test above.
      // All Anvil chains share ETH as the base token, so the
      // isSameBaseToken path is always true and this scenario cannot be
      // exercised.
    });

    it("receives a message sending a bridged token", async function () {
      if (!bridgedErc20BundleData) {
        this.skip();
        return;
      }

      // The bridged token (dest chain's native token) should resolve to
      // the original test token on the destination chain.
      const destTestToken = state.testTokens![destChainId];
      const bridgedAssetId = encodeNtvAssetId(destChainId, destTestToken);
      const destTokenAddr = await getTokenAddressForAsset(destProvider, bridgedAssetId);

      const recipientBalBefore = await getTokenBalance(destProvider, destTokenAddr, ANVIL_RECIPIENT_ADDR);

      const receipt = await executeBundle(destProvider, bridgedErc20BundleData, bridgedErc20SourceChainId);
      expect(receipt.status).to.equal(1);

      const bridgedAmount = ethers.utils.parseUnits("2", 18);
      const recipientBalAfter = await getTokenBalance(destProvider, destTokenAddr, ANVIL_RECIPIENT_ADDR);
      const balDelta = recipientBalAfter.sub(recipientBalBefore);
      expect(
        balDelta.eq(bridgedAmount),
        `recipient bridged token balance should increase by ${bridgedAmount}, got ${balDelta}`
      ).to.be.true;

      console.log(
        `   Bridged ERC20 received on destination: +${ethers.utils.formatUnits(balDelta, 18)} tokens at ${destTokenAddr}`
      );
    });
  });
});
