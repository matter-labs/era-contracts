import { expect } from "chai";
import { Contract, Wallet, ethers, providers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getAbi, getCreationBytecode } from "../../src/core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  ANVIL_RECIPIENT_ADDR,
  INTEROP_CENTER_ADDR,
  L1_CHAIN_ID,
} from "../../src/core/const";
import { deployDummyInteropRecipient, deployRevertingContract } from "../../src/helpers/interop-helpers";

/**
 * 11 - L1InteropHandler
 *
 * Drives the new L1InteropHandler through its happy and unhappy paths against
 * the real L1Bridgehub deployed by the anvil-setup. The Bridgehub uses
 * DummyL1MessageRoot under the hood, which always returns true for
 * `_proveL2LeafInclusionRecursive` — so well-shaped proofs are accepted and
 * we get to exercise the rest of the handler (bundle decoding, replay
 * protection, shadow-account CREATE2, mixed direct/shadow execution).
 *
 * Bundle wire format must match `InteropBundle` / `InteropCall` /
 * `BundleAttributes` declared in `L1InteropHandler.sol`. We reuse
 * `INTEROP_BUNDLE_TUPLE_TYPE` from const.ts because it's identical to the L2
 * Messaging.sol layout the L1 handler mirrors.
 */
describe("11 - L1InteropHandler", function () {
  this.timeout(0);

  // Mirrors L1InteropHandler.sol — kept here as a constant in case the L2 const ever drifts.
  const L1_BUNDLE_TUPLE =
    "tuple(bytes1,uint256,uint256,bytes32,bytes32,tuple(bytes1,bool,address,address,uint256,bytes)[],tuple(bytes,bytes,bool))";

  // Bundle version byte (mirrors the L2 InteropCenter; the L1 handler doesn't gate on this,
  // but we pick a sensible non-zero value to make traces searchable).
  const BUNDLE_VERSION = "0x01";

  // A source chain id that doesn't collide with the anvil-setup chains (mirrors how L2
  // tests pick a sourceChainId for the InteropBundleSent event).
  const SOURCE_CHAIN_ID = 271;

  const abiCoder = ethers.utils.defaultAbiCoder;

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let l1Provider: providers.JsonRpcProvider;
  let deployer: Wallet;
  let handler: Contract;
  let handlerAddr: string;
  let dummyRecipient: string;

  /** Build a well-formed bundle that decodes back to the handler's InteropBundle struct. */
  function buildBundle(
    calls: Array<{ shadowAccount: boolean; to: string; from: string; value: ethers.BigNumberish; data: string }>,
    overrides?: { destinationChainId?: number; sourceChainId?: number; salt?: string }
  ): { bundleBytes: string; bundleMsgHash: string } {
    const interopCalls = calls.map((c) => [
      BUNDLE_VERSION,
      c.shadowAccount,
      c.to,
      c.from,
      ethers.BigNumber.from(c.value),
      c.data,
    ]);
    const bundle = [
      BUNDLE_VERSION,
      ethers.BigNumber.from(overrides?.sourceChainId ?? SOURCE_CHAIN_ID),
      ethers.BigNumber.from(overrides?.destinationChainId ?? L1_CHAIN_ID),
      ethers.constants.HashZero, // destinationBaseTokenAssetId — not consumed by the handler
      overrides?.salt ?? ethers.utils.id(`salt-${Math.random()}`),
      interopCalls,
      ["0x", "0x", false], // BundleAttributes — not consumed by the handler
    ];
    const bundleBytes = abiCoder.encode([L1_BUNDLE_TUPLE], [bundle]);
    return { bundleBytes, bundleMsgHash: ethers.utils.keccak256(bundleBytes) };
  }

  /** Build a well-formed ExecuteBundleParams with the InteropCenter as the l2Sender. */
  function buildExecuteParams(bundleBytes: string, overrides?: { l2Sender?: string; chainId?: number }) {
    return {
      chainId: overrides?.chainId ?? SOURCE_CHAIN_ID,
      l2BatchNumber: 0,
      l2MessageIndex: 0,
      l2TxNumberInBatch: 0,
      l2Sender: overrides?.l2Sender ?? INTEROP_CENTER_ADDR,
      message: bundleBytes,
      merkleProof: [] as string[],
    };
  }

  before(async () => {
    state = runner.loadState();
    if (!state.chains?.l1 || !state.l1InteropContracts?.l1InteropHandler) {
      throw new Error("Deployment state incomplete — L1InteropHandler not deployed");
    }
    l1Provider = new providers.JsonRpcProvider(state.chains.l1.rpcUrl);
    deployer = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
    handlerAddr = state.l1InteropContracts.l1InteropHandler;
    handler = new Contract(handlerAddr, getAbi("L1InteropHandler"), deployer);

    // Fund the handler so it can forward value on non-shadow calls.
    // Shadow-account calls draw from the shadow account's own balance,
    // not from the handler — those tests pre-fund the predicted address.
    await (await deployer.sendTransaction({ to: handlerAddr, value: ethers.utils.parseEther("10") })).wait();

    dummyRecipient = await deployDummyInteropRecipient(l1Provider);
  });

  describe("immutables + deployment", () => {
    it("binds BRIDGE_HUB and L2_INTEROP_CENTER as configured", async () => {
      expect((await handler.BRIDGE_HUB()).toLowerCase()).to.equal(state.l1Addresses!.bridgehub.toLowerCase());
      expect((await handler.L2_INTEROP_CENTER()).toLowerCase()).to.equal(INTEROP_CENTER_ADDR.toLowerCase());
    });

    it("caches the L1ShadowAccount creation-code hash", async () => {
      const expected = ethers.utils.keccak256(getCreationBytecode("L1ShadowAccount"));
      expect(await handler.SHADOW_ACCOUNT_BYTECODE_HASH()).to.equal(expected);
    });
  });

  describe("executeBundle — direct call (shadowAccount=false)", () => {
    it("forwards value to the target and emits CallExecuted + BundleExecuted", async () => {
      const value = ethers.utils.parseUnits("123", "gwei");
      const { bundleBytes, bundleMsgHash } = buildBundle([
        {
          shadowAccount: false,
          to: dummyRecipient,
          from: ANVIL_RECIPIENT_ADDR,
          value,
          data: "0x", // receive()
        },
      ]);

      const recipientBalBefore = await l1Provider.getBalance(dummyRecipient);
      const params = buildExecuteParams(bundleBytes);
      const tx = await handler.executeBundle(params);
      const receipt = await tx.wait();

      // Recipient should have received `value` from the handler.
      const recipientBalAfter = await l1Provider.getBalance(dummyRecipient);
      expect(recipientBalAfter.sub(recipientBalBefore).eq(value), "recipient should receive the forwarded value").to.equal(
        true
      );

      // Status flipped to Executed.
      expect(await handler.bundleStatus(bundleMsgHash)).to.equal(1 /* Status.Executed */);

      // Events.
      const callExecuted = receipt.events?.find((e: { event?: string }) => e.event === "CallExecuted");
      expect(callExecuted, "CallExecuted should be emitted").to.exist;
      expect(callExecuted!.args!.bundleMsgHash).to.equal(bundleMsgHash);
      expect(callExecuted!.args!.callIndex.toNumber()).to.equal(0);
      expect(callExecuted!.args!.via.toLowerCase()).to.equal(handlerAddr.toLowerCase());
      expect(callExecuted!.args!.shadowAccount).to.equal(false);

      const bundleExecuted = receipt.events?.find((e: { event?: string }) => e.event === "BundleExecuted");
      expect(bundleExecuted, "BundleExecuted should be emitted").to.exist;
      expect(bundleExecuted!.args!.bundleMsgHash).to.equal(bundleMsgHash);
      expect(bundleExecuted!.args!.sourceChainId.toNumber()).to.equal(SOURCE_CHAIN_ID);
      expect(bundleExecuted!.args!.callsExecuted.toNumber()).to.equal(1);
    });

    it("reverts AlreadyExecuted on replay", async () => {
      const value = ethers.utils.parseUnits("1", "gwei");
      const { bundleBytes } = buildBundle([
        { shadowAccount: false, to: dummyRecipient, from: ANVIL_RECIPIENT_ADDR, value, data: "0x" },
      ]);
      const params = buildExecuteParams(bundleBytes);

      await (await handler.executeBundle(params)).wait();
      await expect(handler.executeBundle(params)).to.be.reverted;
    });

    it("reverts CallFailed when the underlying target reverts", async () => {
      const reverter = await deployRevertingContract(l1Provider);
      const { bundleBytes } = buildBundle([
        { shadowAccount: false, to: reverter, from: ANVIL_RECIPIENT_ADDR, value: 0, data: "0xdeadbeef" },
      ]);
      await expect(handler.executeBundle(buildExecuteParams(bundleBytes))).to.be.reverted;
    });
  });

  describe("executeBundle — shadow-account calls (shadowAccount=true)", () => {
    /** Fresh sender each test so the (chainId, sender) → shadow-account CREATE2 address is unused. */
    function freshSender(): string {
      return ethers.Wallet.createRandom().address;
    }

    it("lazy-deploys an L1ShadowAccount and routes the call through it (msg.sender == shadow)", async () => {
      const l2Sender = freshSender();
      const predicted = await handler.shadowAccountFor(SOURCE_CHAIN_ID, l2Sender);
      expect(predicted).to.properAddress;

      // Pre-fund the predicted shadow account — shadow calls spend from the shadow's
      // own balance, not the handler's (the contract is explicit about this).
      const value = ethers.utils.parseUnits("1", "gwei");
      await (await deployer.sendTransaction({ to: predicted, value: value.mul(2) })).wait();

      // Before execution, no code at the predicted address.
      expect(await l1Provider.getCode(predicted)).to.equal("0x");

      const { bundleBytes, bundleMsgHash } = buildBundle([
        { shadowAccount: true, to: dummyRecipient, from: l2Sender, value, data: "0x" },
      ]);
      const recipientBalBefore = await l1Provider.getBalance(dummyRecipient);
      const tx = await handler.executeBundle(buildExecuteParams(bundleBytes));
      const receipt = await tx.wait();

      // Shadow account is now deployed.
      const code = await l1Provider.getCode(predicted);
      expect(code).to.not.equal("0x");

      // Recipient received value — from the shadow account, not the handler.
      const recipientBalAfter = await l1Provider.getBalance(dummyRecipient);
      expect(recipientBalAfter.sub(recipientBalBefore).eq(value)).to.equal(true);

      // ShadowAccountDeployed event with the predicted address.
      const deployedEv = receipt.events?.find((e: { event?: string }) => e.event === "ShadowAccountDeployed");
      expect(deployedEv, "ShadowAccountDeployed should be emitted").to.exist;
      expect(deployedEv!.args!.shadowAccount.toLowerCase()).to.equal(predicted.toLowerCase());
      expect(deployedEv!.args!.l2ChainId.toNumber()).to.equal(SOURCE_CHAIN_ID);
      expect(deployedEv!.args!.l2Sender.toLowerCase()).to.equal(l2Sender.toLowerCase());

      // CallExecuted attributed the call to the shadow address (via=shadow).
      const callEv = receipt.events?.find((e: { event?: string }) => e.event === "CallExecuted");
      expect(callEv!.args!.via.toLowerCase()).to.equal(predicted.toLowerCase());
      expect(callEv!.args!.shadowAccount).to.equal(true);

      // bundleMsgHash matches what we computed off-chain.
      expect(callEv!.args!.bundleMsgHash).to.equal(bundleMsgHash);

      // Sanity: the shadow account's INTEROP_HANDLER immutable points at our handler.
      const shadow = new Contract(predicted, getAbi("L1ShadowAccount"), l1Provider);
      expect((await shadow.INTEROP_HANDLER()).toLowerCase()).to.equal(handlerAddr.toLowerCase());
    });

    it("reuses the existing shadow account on a second bundle (no second ShadowAccountDeployed)", async () => {
      // Same (chainId, sender) across two bundles → same CREATE2 address, no re-deploy.
      const l2Sender = freshSender();
      const predicted = await handler.shadowAccountFor(SOURCE_CHAIN_ID, l2Sender);
      const value = ethers.utils.parseUnits("1", "gwei");
      await (await deployer.sendTransaction({ to: predicted, value: value.mul(4) })).wait();

      // First bundle deploys the shadow account.
      const first = buildBundle(
        [{ shadowAccount: true, to: dummyRecipient, from: l2Sender, value, data: "0x" }],
        { salt: ethers.utils.id("reuse-1") }
      );
      await (await handler.executeBundle(buildExecuteParams(first.bundleBytes))).wait();

      // Second bundle (different salt → different msg hash, so no replay-protection collision)
      // must not emit ShadowAccountDeployed again.
      const second = buildBundle(
        [{ shadowAccount: true, to: dummyRecipient, from: l2Sender, value, data: "0x" }],
        { salt: ethers.utils.id("reuse-2") }
      );
      const receipt = await (await handler.executeBundle(buildExecuteParams(second.bundleBytes))).wait();

      const deployedEv = receipt.events?.find((e: { event?: string }) => e.event === "ShadowAccountDeployed");
      expect(deployedEv, "shadow account should not be re-deployed").to.be.undefined;
      // But CallExecuted is still attributed to the same shadow address.
      const callEv = receipt.events?.find((e: { event?: string }) => e.event === "CallExecuted");
      expect(callEv!.args!.via.toLowerCase()).to.equal(predicted.toLowerCase());
    });

    it("supports a mixed bundle with direct + shadow calls in a single transaction", async () => {
      const l2Sender = freshSender();
      const predicted = await handler.shadowAccountFor(SOURCE_CHAIN_ID, l2Sender);
      const shadowValue = ethers.utils.parseUnits("1", "gwei");
      const directValue = ethers.utils.parseUnits("2", "gwei");

      await (await deployer.sendTransaction({ to: predicted, value: shadowValue.mul(2) })).wait();

      const { bundleBytes } = buildBundle([
        { shadowAccount: false, to: dummyRecipient, from: ANVIL_RECIPIENT_ADDR, value: directValue, data: "0x" },
        { shadowAccount: true, to: dummyRecipient, from: l2Sender, value: shadowValue, data: "0x" },
      ]);

      const recipientBalBefore = await l1Provider.getBalance(dummyRecipient);
      const receipt = await (await handler.executeBundle(buildExecuteParams(bundleBytes))).wait();
      const recipientBalAfter = await l1Provider.getBalance(dummyRecipient);

      // Both call values land at the recipient.
      expect(recipientBalAfter.sub(recipientBalBefore).eq(directValue.add(shadowValue))).to.equal(true);

      // Two CallExecuted events: index 0 (direct) and index 1 (shadow).
      const callEvents = receipt.events!.filter((e: { event?: string }) => e.event === "CallExecuted");
      expect(callEvents.length).to.equal(2);
      expect(callEvents[0].args!.shadowAccount).to.equal(false);
      expect(callEvents[1].args!.shadowAccount).to.equal(true);
      expect(callEvents[1].args!.via.toLowerCase()).to.equal(predicted.toLowerCase());
    });
  });

  describe("executeBundle — input validation", () => {
    it("reverts WrongL2Sender when l2Sender != L2_INTEROP_CENTER", async () => {
      const { bundleBytes } = buildBundle([
        { shadowAccount: false, to: dummyRecipient, from: ANVIL_RECIPIENT_ADDR, value: 0, data: "0x" },
      ]);
      // Pass a random address as the L2 sender — the handler must reject.
      const params = buildExecuteParams(bundleBytes, { l2Sender: ethers.Wallet.createRandom().address });
      await expect(handler.executeBundle(params)).to.be.reverted;
    });

    it("reverts WrongDestinationChain when bundle.destinationChainId != block.chainid", async () => {
      const { bundleBytes } = buildBundle(
        [{ shadowAccount: false, to: dummyRecipient, from: ANVIL_RECIPIENT_ADDR, value: 0, data: "0x" }],
        { destinationChainId: L1_CHAIN_ID + 1 }
      );
      await expect(handler.executeBundle(buildExecuteParams(bundleBytes))).to.be.reverted;
    });
  });

  describe("shadowAccountFor", () => {
    it("is deterministic given (chainId, sender) — same inputs yield same address", async () => {
      const l2Sender = ethers.Wallet.createRandom().address;
      const a = await handler.shadowAccountFor(SOURCE_CHAIN_ID, l2Sender);
      const b = await handler.shadowAccountFor(SOURCE_CHAIN_ID, l2Sender);
      expect(a).to.equal(b);
    });

    it("changes when either chainId or sender changes", async () => {
      const sender1 = ethers.Wallet.createRandom().address;
      const sender2 = ethers.Wallet.createRandom().address;
      const a = await handler.shadowAccountFor(SOURCE_CHAIN_ID, sender1);
      const b = await handler.shadowAccountFor(SOURCE_CHAIN_ID, sender2);
      const c = await handler.shadowAccountFor(SOURCE_CHAIN_ID + 1, sender1);
      expect(a).to.not.equal(b);
      expect(a).to.not.equal(c);
    });
  });
});
