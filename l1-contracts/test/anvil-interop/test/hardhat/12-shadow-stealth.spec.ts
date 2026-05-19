import { expect } from "chai";
import { Contract, Wallet, ethers, providers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getAbi, getCreationBytecode } from "../../src/core/contracts";
import {
  ANVIL_ACCOUNT2_ADDR,
  ANVIL_ACCOUNT2_PRIVATE_KEY,
  ANVIL_DEFAULT_ACCOUNT_ADDR,
  ANVIL_DEFAULT_PRIVATE_KEY,
} from "../../src/core/const";
import { impersonateAndRun } from "../../src/core/utils";
import { deployRevertingContract } from "../../src/helpers/interop-helpers";

/**
 * 12 - ShadowAccountFactory + StealthShadowAccount + StealthSender
 *
 * Covers the per-user stealth surface added on the l1-interop-contracts branch:
 *   • ShadowAccountFactory   — CREATE2-deploys StealthShadowAccount(salt, owner) and
 *                              computes the address off-chain.
 *   • StealthShadowAccount   — handler-only call surface; deployed by the factory.
 *   • StealthSender          — secret registration + ownerHash reverse map. The
 *                              `receiveReturn` path is gated to the configured
 *                              handler; we drive it by impersonating the handler
 *                              on Anvil (matching the existing v31 upgrade tests).
 *
 * The handler used for these contracts is the same L1InteropHandler from spec 11,
 * but we don't drive it end-to-end through `executeBundle` here — that surface is
 * already covered in spec 11. The point is to exercise these contracts' own paths.
 */
describe("12 - Shadow / Stealth contracts", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let l1Provider: providers.JsonRpcProvider;
  let admin: Wallet;
  let factory: Contract;
  let stealthSender: Contract;
  let handlerAddr: string;

  before(() => {
    state = runner.loadState();
    if (
      !state.chains?.l1 ||
      !state.l1InteropContracts?.shadowAccountFactory ||
      !state.l1InteropContracts?.stealthSender ||
      !state.l1InteropContracts?.l1InteropHandler
    ) {
      throw new Error("Deployment state incomplete — stealth contracts not deployed");
    }
    l1Provider = new providers.JsonRpcProvider(state.chains.l1.rpcUrl);
    admin = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
    factory = new Contract(state.l1InteropContracts.shadowAccountFactory, getAbi("ShadowAccountFactory"), admin);
    stealthSender = new Contract(state.l1InteropContracts.stealthSender, getAbi("StealthSender"), admin);
    handlerAddr = state.l1InteropContracts.l1InteropHandler;
  });

  describe("ShadowAccountFactory", () => {
    it("computeAddress is deterministic and agrees with deploy(...)", async () => {
      const salt = ethers.utils.id("compute-test-1");
      const ownerChainId = 271;
      const owner = ethers.Wallet.createRandom().address;

      const predicted = await factory.computeAddress(salt, ownerChainId, owner);
      expect(predicted).to.properAddress;

      // Not deployed yet → isDeployed=false.
      expect(await factory.isDeployed(salt, ownerChainId, owner)).to.equal(false);

      const tx = await factory.deploy(salt, ownerChainId, owner);
      const receipt = await tx.wait();

      // Event payload matches predicted.
      const ev = receipt.events?.find((e: { event?: string }) => e.event === "StealthShadowDeployed");
      expect(ev, "StealthShadowDeployed should be emitted").to.exist;
      expect(ev!.args!.shadowAccount.toLowerCase()).to.equal(predicted.toLowerCase());
      expect(ev!.args!.salt).to.equal(salt);
      expect(ev!.args!.ownerChainId.toNumber()).to.equal(ownerChainId);
      expect(ev!.args!.ownerAddress.toLowerCase()).to.equal(owner.toLowerCase());

      // isDeployed flips to true now.
      expect(await factory.isDeployed(salt, ownerChainId, owner)).to.equal(true);
      expect(await l1Provider.getCode(predicted)).to.not.equal("0x");

      // The deployed shadow's immutables match what we supplied.
      const shadow = new Contract(predicted, getAbi("StealthShadowAccount"), l1Provider);
      expect((await shadow.OWNER_CHAIN_ID()).toNumber()).to.equal(ownerChainId);
      expect((await shadow.OWNER_ADDRESS()).toLowerCase()).to.equal(owner.toLowerCase());
      expect((await shadow.INTEROP_HANDLER()).toLowerCase()).to.equal(handlerAddr.toLowerCase());
    });

    it("reverts on duplicate deploy at the same (salt, owner) — CREATE2 collision", async () => {
      const salt = ethers.utils.id("dupe-test");
      const ownerChainId = 272;
      const owner = ethers.Wallet.createRandom().address;

      await (await factory.deploy(salt, ownerChainId, owner)).wait();
      await expect(factory.deploy(salt, ownerChainId, owner)).to.be.reverted;
    });

    it("different (chainId, owner) yield different stealth addresses for the same salt", async () => {
      const salt = ethers.utils.id("disjoint-test");
      const ownerA = ethers.Wallet.createRandom().address;
      const ownerB = ethers.Wallet.createRandom().address;

      const a = await factory.computeAddress(salt, 1, ownerA);
      const b = await factory.computeAddress(salt, 1, ownerB);
      const c = await factory.computeAddress(salt, 2, ownerA);
      expect(a).to.not.equal(b);
      expect(a).to.not.equal(c);
    });
  });

  describe("StealthShadowAccount", () => {
    let shadow: Contract;
    let shadowAddr: string;

    before(async () => {
      const salt = ethers.utils.id("exec-suite");
      const owner = ethers.Wallet.createRandom().address;
      shadowAddr = await factory.computeAddress(salt, 999, owner);
      await (await factory.deploy(salt, 999, owner)).wait();
      shadow = new Contract(shadowAddr, getAbi("StealthShadowAccount"), l1Provider);

      // Fund the shadow so it can forward value during executeFromHandler.
      await (await admin.sendTransaction({ to: shadowAddr, value: ethers.utils.parseEther("1") })).wait();
    });

    it("rejects executeFromHandler from a non-handler caller", async () => {
      const shadowAsUser = shadow.connect(admin);
      await expect(shadowAsUser.executeFromHandler(ANVIL_DEFAULT_ACCOUNT_ADDR, 0, "0x")).to.be.reverted;
    });

    it("forwards value + data when called by the configured handler", async () => {
      // Reuse Anvil account #2 as the recipient — we want to assert a value transfer.
      const recipient = ANVIL_ACCOUNT2_ADDR;
      const value = ethers.utils.parseUnits("100", "gwei");

      const balBefore = await l1Provider.getBalance(recipient);
      await impersonateAndRun(l1Provider, handlerAddr, async (signer) => {
        const tx = await shadow.connect(signer).executeFromHandler(recipient, value, "0x");
        await tx.wait();
      });
      const balAfter = await l1Provider.getBalance(recipient);
      expect(balAfter.sub(balBefore).eq(value)).to.equal(true);
    });

    it("propagates CallFailed when the target reverts", async () => {
      const reverter = await deployRevertingContract(l1Provider);
      await impersonateAndRun(l1Provider, handlerAddr, async (signer) => {
        await expect(shadow.connect(signer).executeFromHandler(reverter, 0, "0xdeadbeef")).to.be.reverted;
      });
    });
  });

  describe("StealthSender", () => {
    it("binds INTEROP_HANDLER as configured", async () => {
      expect((await stealthSender.INTEROP_HANDLER()).toLowerCase()).to.equal(handlerAddr.toLowerCase());
    });

    it("register stores the secret, exposes ownerHashOf, and emits SecretRegistered", async () => {
      // Use a fresh wallet so we don't collide with re-runs / sister tests.
      const user = ethers.Wallet.createRandom().connect(l1Provider);
      await (await admin.sendTransaction({ to: user.address, value: ethers.utils.parseEther("1") })).wait();
      const senderAsUser = stealthSender.connect(user);

      expect(await stealthSender.isRegistered(user.address)).to.equal(false);

      const secret = ethers.utils.id("user-secret");
      const expectedHash = ethers.utils.solidityKeccak256(["address", "bytes32"], [user.address, secret]);

      const tx = await senderAsUser.register(secret);
      const receipt = await tx.wait();

      const ev = receipt.events?.find((e: { event?: string }) => e.event === "SecretRegistered");
      expect(ev, "SecretRegistered should be emitted").to.exist;
      expect(ev!.args!.user.toLowerCase()).to.equal(user.address.toLowerCase());
      expect(ev!.args!.ownerHash).to.equal(expectedHash);

      expect(await stealthSender.isRegistered(user.address)).to.equal(true);
      expect(await stealthSender.secrets(user.address)).to.equal(secret);
      expect(await stealthSender.ownerHashOf(user.address)).to.equal(expectedHash);
      expect((await stealthSender.ownerHashToUser(expectedHash)).toLowerCase()).to.equal(user.address.toLowerCase());
    });

    it("rejects zero secret and double-registration", async () => {
      // Use a different fresh wallet for the AlreadyRegistered path to keep tests isolated.
      const user = ethers.Wallet.createRandom().connect(l1Provider);
      await (await admin.sendTransaction({ to: user.address, value: ethers.utils.parseEther("1") })).wait();
      const senderAsUser = stealthSender.connect(user);

      await expect(senderAsUser.register(ethers.constants.HashZero)).to.be.reverted;

      await (await senderAsUser.register(ethers.utils.id("first-secret"))).wait();
      await expect(senderAsUser.register(ethers.utils.id("second-secret"))).to.be.reverted;
    });

    it("ownerHashOf reverts NotRegistered for an unregistered user", async () => {
      const stranger = ethers.Wallet.createRandom().address;
      await expect(stealthSender.ownerHashOf(stranger)).to.be.reverted;
    });

    it("rejects receiveReturn from non-handler caller (NotInteropHandler)", async () => {
      const someHash = ethers.utils.id("doesnt-matter");
      // ANVIL_DEFAULT_ACCOUNT_ADDR is NOT the configured handler, so this must revert.
      await expect(stealthSender.receiveReturn(someHash, { value: 1 })).to.be.reverted;
    });

    it("receiveReturn from the handler forwards value to the registered user", async () => {
      // 1. Register a user → ownerHash is known.
      const user = new Wallet(ANVIL_ACCOUNT2_PRIVATE_KEY, l1Provider);

      // The ANVIL_ACCOUNT2 user may already be registered by another test on this same
      // chain state — register if needed; otherwise use the existing secret.
      let isReg = await stealthSender.isRegistered(user.address);
      if (!isReg) {
        await (await stealthSender.connect(user).register(ethers.utils.id("acct2-secret"))).wait();
        isReg = true;
      }
      const ownerHash = await stealthSender.ownerHashOf(user.address);

      // 2. Impersonate the handler and forward value through receiveReturn.
      const value = ethers.utils.parseUnits("42", "gwei");
      const balBefore = await l1Provider.getBalance(user.address);

      await impersonateAndRun(l1Provider, handlerAddr, async (signer) => {
        const tx = await stealthSender.connect(signer).receiveReturn(ownerHash, { value });
        await tx.wait();
      });

      const balAfter = await l1Provider.getBalance(user.address);
      // user.address doesn't pay gas here (handler-impersonated tx pays), so the
      // delta should be exactly `value`.
      expect(balAfter.sub(balBefore).eq(value)).to.equal(true);
    });

    it("receiveReturn reverts UnknownOwnerHash when the hash is unmapped", async () => {
      const unknown = ethers.utils.id("never-registered");
      await impersonateAndRun(l1Provider, handlerAddr, async (signer) => {
        await expect(stealthSender.connect(signer).receiveReturn(unknown, { value: 1 })).to.be.reverted;
      });
    });
  });

  describe("L1ShadowAccount (via handler) — direct access guard", () => {
    // The handler is the only legitimate way to construct an L1ShadowAccount with
    // the right INTEROP_HANDLER. But the contract itself is small — we cover the
    // negative path (non-handler caller) here by deploying it ad-hoc and asserting
    // that executeFromHandler is locked down. The constructor-set immutable means
    // the deployer becomes the handler; we use the admin wallet to confirm the
    // guard is wired correctly.
    it("rejects executeFromHandler from a non-handler caller", async () => {
      const shadowFactory = new ethers.ContractFactory(
        getAbi("L1ShadowAccount"),
        getCreationBytecode("L1ShadowAccount"),
        admin
      );
      const shadow = await shadowFactory.deploy();
      await shadow.deployed();
      // admin deployed it → admin is INTEROP_HANDLER on this instance.
      // A *different* signer must be rejected.
      const stranger = ethers.Wallet.createRandom().connect(l1Provider);
      await (await admin.sendTransaction({ to: stranger.address, value: ethers.utils.parseEther("1") })).wait();
      await expect(shadow.connect(stranger).executeFromHandler(ANVIL_DEFAULT_ACCOUNT_ADDR, 0, "0x")).to.be.reverted;
    });
  });
});
