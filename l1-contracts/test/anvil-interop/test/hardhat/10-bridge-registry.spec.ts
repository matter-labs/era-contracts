import { expect } from "chai";
import { Contract, Wallet, ethers, providers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getAbi, getCreationBytecode } from "../../src/core/contracts";
import {
  ANVIL_ACCOUNT2_PRIVATE_KEY,
  ANVIL_DEFAULT_ACCOUNT_ADDR,
  ANVIL_DEFAULT_PRIVATE_KEY,
  ANVIL_RECIPIENT_ADDR,
} from "../../src/core/const";

/**
 * 10 - BridgeRegistry
 *
 * Exercises the L1 BridgeRegistry that gates user announcements with role-based
 * access control + a per-user daily limit + a global pause. The contract is
 * deployed once per anvil-setup run; we use a fresh user (Anvil account #1) so
 * tests don't interfere with daily-limit usage from earlier runs.
 *
 * Notes:
 *  • The day index is `block.timestamp / 1 days`. We advance time via
 *    `evm_mine` + `evm_setNextBlockTimestamp` rather than mocking — this
 *    keeps the real flow in coverage and validates the rollover boundary.
 *  • DEFAULT_ADMIN_ROLE is held by ANVIL_DEFAULT_ACCOUNT_ADDR (set at deploy).
 */
describe("10 - BridgeRegistry", function () {
  this.timeout(0);

  // BridgeRegistry.Direction enum values, mirroring the Solidity definition.
  const DIRECTION_DEPOSIT = 0;
  const DIRECTION_WITHDRAW = 1;

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let l1Provider: providers.JsonRpcProvider;
  let admin: Wallet;
  let user: Wallet;
  let registry: Contract;
  let registryAsUser: Contract;

  before(async () => {
    state = runner.loadState();
    if (!state.chains?.l1 || !state.l1InteropContracts?.bridgeRegistry) {
      throw new Error("Deployment state incomplete — BridgeRegistry not deployed");
    }
    l1Provider = new providers.JsonRpcProvider(state.chains.l1.rpcUrl);
    admin = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
    // Use Anvil account #2 (account #1 is reserved for ANVIL_RECIPIENT_ADDR in other specs);
    // a fresh wallet sidesteps any state from other specs touching the registry.
    user = new Wallet(ANVIL_ACCOUNT2_PRIVATE_KEY, l1Provider);
    const abi = getAbi("BridgeRegistry");
    registry = new Contract(state.l1InteropContracts.bridgeRegistry, abi, admin);
    registryAsUser = registry.connect(user);

    // Grant BRIDGE_USER_ROLE to our test user (idempotent: AccessControl.grantRole no-ops on re-grant).
    const bridgeUserRole = await registry.BRIDGE_USER_ROLE();
    const tx = await registry.grantRole(bridgeUserRole, user.address);
    await tx.wait();
  });

  describe("deployment + role wiring", () => {
    it("grants DEFAULT_ADMIN_ROLE to the configured admin", async () => {
      const defaultAdminRole = await registry.DEFAULT_ADMIN_ROLE();
      expect(await registry.hasRole(defaultAdminRole, ANVIL_DEFAULT_ACCOUNT_ADDR)).to.equal(true);
    });

    it("starts unpaused", async () => {
      expect(await registry.paused()).to.equal(false);
    });

    it("reverts on zero admin at construction (sanity — fresh deploy)", async () => {
      const factory = new ethers.ContractFactory(
        getAbi("BridgeRegistry"),
        getCreationBytecode("BridgeRegistry"),
        admin
      );
      await expect(factory.deploy(ethers.constants.AddressZero)).to.be.reverted;
    });
  });

  describe("setDailyLimit", () => {
    it("admin can set + reset a user's daily limit and emits DailyLimitUpdated", async () => {
      const newLimit = ethers.utils.parseEther("5");

      const before = await registry.dailyLimit(user.address);
      const tx = await registry.setDailyLimit(user.address, newLimit);
      const receipt = await tx.wait();

      // Event assertion: DailyLimitUpdated(user, oldLimit, newLimit)
      const ev = receipt.events?.find((e: { event?: string }) => e.event === "DailyLimitUpdated");
      expect(ev, "DailyLimitUpdated should be emitted").to.exist;
      expect(ev!.args!.user).to.equal(user.address);
      expect(ev!.args!.oldLimit.eq(before)).to.equal(true);
      expect(ev!.args!.newLimit.eq(newLimit)).to.equal(true);

      expect((await registry.dailyLimit(user.address)).eq(newLimit)).to.equal(true);
    });

    it("non-admin cannot set a daily limit (AccessControl: missing role)", async () => {
      await expect(registryAsUser.setDailyLimit(user.address, 1)).to.be.reverted;
    });

    it("reverts with ZeroAddress for the zero user", async () => {
      // Custom error revert — ethers v5 / waffle here can't decode custom-error names,
      // so we assert the bare revert (matches the pattern of the other 41+ specs).
      await expect(registry.setDailyLimit(ethers.constants.AddressZero, 1)).to.be.reverted;
    });
  });

  describe("announceBridge happy path", () => {
    before(async () => {
      // Generous limit for the happy-path tests; specific tests below override.
      const tx = await registry.setDailyLimit(user.address, ethers.utils.parseEther("100"));
      await tx.wait();
    });

    it("emits BridgeAnnounced and updates usedToday on a deposit announcement", async () => {
      const amount = ethers.utils.parseEther("1");
      const opsHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ops-deposit-1"));
      const delegate = ANVIL_RECIPIENT_ADDR;
      const usedBefore = await registry.usedToday(user.address);

      const tx = await registryAsUser.announceBridge(DIRECTION_DEPOSIT, amount, opsHash, delegate);
      const receipt = await tx.wait();

      const ev = receipt.events?.find((e: { event?: string }) => e.event === "BridgeAnnounced");
      expect(ev, "BridgeAnnounced should be emitted").to.exist;
      expect(ev!.args!.user).to.equal(user.address);
      expect(ev!.args!.direction).to.equal(DIRECTION_DEPOSIT);
      expect(ev!.args!.amount.eq(amount)).to.equal(true);
      expect(ev!.args!.opsHash).to.equal(opsHash);
      expect(ev!.args!.delegate).to.equal(delegate);

      const usedAfter = await registry.usedToday(user.address);
      expect(usedAfter.eq(usedBefore.add(amount)), "usedToday should advance by exactly amount").to.equal(true);
    });

    it("supports the withdraw direction and accumulates within the same day", async () => {
      const amount = ethers.utils.parseEther("2");
      const opsHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ops-withdraw-1"));
      const usedBefore = await registry.usedToday(user.address);

      const tx = await registryAsUser.announceBridge(DIRECTION_WITHDRAW, amount, opsHash, user.address);
      const receipt = await tx.wait();

      const ev = receipt.events?.find((e: { event?: string }) => e.event === "BridgeAnnounced");
      expect(ev!.args!.direction).to.equal(DIRECTION_WITHDRAW);

      const usedAfter = await registry.usedToday(user.address);
      expect(usedAfter.eq(usedBefore.add(amount)), "withdraw should also count toward usedToday").to.equal(true);
    });
  });

  describe("announceBridge guards", () => {
    it("reverts ZeroAmount on amount=0", async () => {
      const opsHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ops-zero"));
      await expect(registryAsUser.announceBridge(DIRECTION_DEPOSIT, 0, opsHash, user.address)).to.be.reverted;
    });

    it("reverts EmptyOpsHash on opsHash=0", async () => {
      await expect(
        registryAsUser.announceBridge(DIRECTION_DEPOSIT, 1, ethers.constants.HashZero, user.address)
      ).to.be.reverted;
    });

    it("reverts when caller lacks BRIDGE_USER_ROLE", async () => {
      // Spin up a separate wallet that we never grant BRIDGE_USER_ROLE to.
      const unauth = ethers.Wallet.createRandom().connect(l1Provider);
      // Fund unauth so the revert isn't a balance issue.
      await (await admin.sendTransaction({ to: unauth.address, value: ethers.utils.parseEther("1") })).wait();

      const opsHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ops-unauth"));
      const registryAsUnauth = registry.connect(unauth);
      await expect(registryAsUnauth.announceBridge(DIRECTION_DEPOSIT, 1, opsHash, unauth.address)).to.be.reverted;
    });
  });

  describe("daily limit enforcement", () => {
    let limitedUser: Wallet;
    let registryAsLimited: Contract;

    before(async () => {
      // Fresh wallet so usedToday starts at zero — independent of earlier tests.
      limitedUser = ethers.Wallet.createRandom().connect(l1Provider);
      await (await admin.sendTransaction({ to: limitedUser.address, value: ethers.utils.parseEther("1") })).wait();

      const bridgeUserRole = await registry.BRIDGE_USER_ROLE();
      await (await registry.grantRole(bridgeUserRole, limitedUser.address)).wait();
      await (await registry.setDailyLimit(limitedUser.address, ethers.utils.parseEther("3"))).wait();

      registryAsLimited = registry.connect(limitedUser);
    });

    it("rejects when amount > remaining limit with DailyLimitExceeded(remaining)", async () => {
      const opsHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ops-limit-1"));
      const big = ethers.utils.parseEther("4"); // limit is 3
      await expect(registryAsLimited.announceBridge(DIRECTION_DEPOSIT, big, opsHash, limitedUser.address)).to.be
        .reverted;
    });

    it("accepts amounts that stay within remaining limit, then rejects the overflow", async () => {
      const opsHash1 = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ops-limit-2a"));
      await (await registryAsLimited.announceBridge(DIRECTION_DEPOSIT, ethers.utils.parseEther("2"), opsHash1, limitedUser.address)).wait();

      // Now 1 ETH remains — a 2 ETH announcement must fail.
      const opsHash2 = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ops-limit-2b"));
      await expect(
        registryAsLimited.announceBridge(DIRECTION_DEPOSIT, ethers.utils.parseEther("2"), opsHash2, limitedUser.address)
      ).to.be.reverted;

      // And exactly 1 ETH must succeed.
      const opsHash3 = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ops-limit-2c"));
      await (await registryAsLimited.announceBridge(DIRECTION_DEPOSIT, ethers.utils.parseEther("1"), opsHash3, limitedUser.address)).wait();
    });

    it("resets usage on day rollover (advance time past 1 day boundary)", async () => {
      // Exhaust the day-1 budget first.
      const remaining = (await registry.dailyLimit(limitedUser.address)).sub(
        await registry.usedToday(limitedUser.address)
      );
      if (remaining.gt(0)) {
        const opsHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ops-day1-drain"));
        await (await registryAsLimited.announceBridge(DIRECTION_DEPOSIT, remaining, opsHash, limitedUser.address)).wait();
      }
      expect(
        (await registry.usedToday(limitedUser.address)).eq(await registry.dailyLimit(limitedUser.address)),
        "limit should be exhausted at the end of day 1"
      ).to.equal(true);

      // Advance time by >1 day (use anvil's evm_setNextBlockTimestamp). The chain
      // shares state with other specs, so we use the current timestamp + 1 day + slack.
      const currentBlock = await l1Provider.getBlock("latest");
      const newTs = currentBlock.timestamp + 24 * 60 * 60 + 60;
      await l1Provider.send("evm_setNextBlockTimestamp", [newTs]);
      await l1Provider.send("evm_mine", []);

      // A fresh announcement up to the full daily limit should now succeed.
      const opsHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ops-day2"));
      const full = await registry.dailyLimit(limitedUser.address);
      await (await registryAsLimited.announceBridge(DIRECTION_DEPOSIT, full, opsHash, limitedUser.address)).wait();

      expect(
        (await registry.usedToday(limitedUser.address)).eq(full),
        "usedToday on day 2 should equal the full limit again"
      ).to.equal(true);
    });
  });

  describe("pause / unpause", () => {
    let pauserUser: Wallet;
    let registryAsPauser: Contract;

    before(async () => {
      pauserUser = ethers.Wallet.createRandom().connect(l1Provider);
      await (await admin.sendTransaction({ to: pauserUser.address, value: ethers.utils.parseEther("1") })).wait();
      const pauserRole = await registry.PAUSER_ROLE();
      await (await registry.grantRole(pauserRole, pauserUser.address)).wait();
      registryAsPauser = registry.connect(pauserUser);
    });

    it("PAUSER_ROLE holder can pause and unpause; non-pauser cannot", async () => {
      await (await registryAsPauser.pause()).wait();
      expect(await registry.paused()).to.equal(true);

      // While paused, even a fully-authorized user cannot announce.
      const opsHash = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("ops-paused"));
      await expect(registryAsUser.announceBridge(DIRECTION_DEPOSIT, 1, opsHash, user.address)).to.be.reverted;

      // Non-pauser unpause must fail.
      await expect(registryAsUser.unpause()).to.be.reverted;

      // Pauser can unpause.
      await (await registryAsPauser.unpause()).wait();
      expect(await registry.paused()).to.equal(false);
    });
  });
});
