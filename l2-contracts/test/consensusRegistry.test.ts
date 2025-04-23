import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import * as hre from "hardhat";
import { Provider, Wallet } from "zksync-ethers";
import type { ConsensusRegistry } from "../typechain";
import { ConsensusRegistryFactory } from "../typechain";
import { expect } from "chai";
import { ethers } from "ethers";
import { Interface } from "ethers/lib/utils";

const richAccount = {
  address: "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049",
  privateKey: "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110",
};

const gasLimit = 100_000_000;

const CONSENSUS_REGISTRY_ARTIFACT = hre.artifacts.readArtifactSync("ConsensusRegistry");
const CONSENSUS_REGISTRY_INTERFACE = new Interface(CONSENSUS_REGISTRY_ARTIFACT.abi);

describe("ConsensusRegistry", function () {
  const provider = new Provider(hre.config.networks.localhost.url);
  const owner = new Wallet(richAccount.privateKey, provider);
  const nonOwner = new Wallet(Wallet.createRandom().privateKey, provider);
  const validators = [];
  const validatorEntries = [];
  let registry: ConsensusRegistry;

  before("Initialize", async function () {
    // Deploy.
    const deployer = new Deployer(hre, owner);
    const registryInstance = await deployer.deploy(await deployer.loadArtifact("ConsensusRegistry"), []);
    const proxyAdmin = await deployer.deploy(await deployer.loadArtifact("ProxyAdmin"), []);
    const proxyInitializationParams = CONSENSUS_REGISTRY_INTERFACE.encodeFunctionData("initialize", [owner.address]);
    const proxyInstance = await deployer.deploy(await deployer.loadArtifact("TransparentUpgradeableProxy"), [
      registryInstance.address,
      proxyAdmin.address,
      proxyInitializationParams,
    ]);
    registry = ConsensusRegistryFactory.connect(proxyInstance.address, owner);

    // Fund nonOwner.
    await (
      await owner.sendTransaction({
        to: nonOwner.address,
        value: ethers.utils.parseEther("100"),
      })
    ).wait();

    // Prepare the validator list.
    const numValidators = 10;
    for (let i = 0; i < numValidators; i++) {
      const validator = makeRandomValidator(provider);
      const validatorEntry = makeRandomValidatorEntry(validator, i);
      validators.push(validator);
      validatorEntries.push(validatorEntry);
    }

    // Fund the first validator owner.
    await (
      await owner.sendTransaction({
        to: validators[0].ownerKey.address,
        value: ethers.utils.parseEther("100"),
      })
    ).wait();
  });

  it("Should set the owner as provided in constructor", async function () {
    expect(await registry.owner()).to.equal(owner.address);
  });

  it("Should add validators to registry", async function () {
    for (let i = 0; i < validators.length; i++) {
      await (
        await registry.add(
          validatorEntries[i].ownerAddr,
          validatorEntries[i].validatorWeight,
          validatorEntries[i].validatorPubKey,
          validatorEntries[i].validatorPoP
        )
      ).wait();
    }

    expect(await registry.numValidators()).to.equal(validators.length);

    for (let i = 0; i < validators.length; i++) {
      const validatorOwner = await registry.validatorOwners(i);
      expect(validatorOwner).to.equal(validatorEntries[i].ownerAddr);
      const validator = await registry.validators(validatorOwner);
      expect(validator.lastSnapshotCommit).to.equal(0);
      expect(validator.previousSnapshotCommit).to.equal(0);

      // 'Latest' is expected to match the added validator's attributes.
      expect(validator.latest.active).to.equal(true);
      expect(validator.latest.removed).to.equal(false);
      expect(validator.latest.weight).to.equal(validatorEntries[i].validatorWeight);
      expect(validator.latest.pubKey.a).to.equal(validatorEntries[i].validatorPubKey.a);
      expect(validator.latest.pubKey.b).to.equal(validatorEntries[i].validatorPubKey.b);
      expect(validator.latest.pubKey.c).to.equal(validatorEntries[i].validatorPubKey.c);
      expect(validator.latest.proofOfPossession.a).to.equal(validatorEntries[i].validatorPoP.a);
      expect(validator.latest.proofOfPossession.b).to.equal(validatorEntries[i].validatorPoP.b);

      // 'Snapshot' is expected to have zero values.
      expect(validator.snapshot.active).to.equal(false);
      expect(validator.snapshot.removed).to.equal(false);
      expect(validator.snapshot.weight).to.equal(0);
      expect(ethers.utils.arrayify(validator.snapshot.pubKey.a)).to.deep.equal(new Uint8Array(32));
      expect(ethers.utils.arrayify(validator.snapshot.pubKey.b)).to.deep.equal(new Uint8Array(32));
      expect(ethers.utils.arrayify(validator.snapshot.pubKey.c)).to.deep.equal(new Uint8Array(32));
      expect(ethers.utils.arrayify(validator.snapshot.proofOfPossession.a)).to.deep.equal(new Uint8Array(32));
      expect(ethers.utils.arrayify(validator.snapshot.proofOfPossession.b)).to.deep.equal(new Uint8Array(16));

      // 'Previous snapshot' is expected to have zero values.
      expect(validator.previousSnapshot.active).to.equal(false);
      expect(validator.previousSnapshot.removed).to.equal(false);
      expect(validator.previousSnapshot.weight).to.equal(0);
      expect(ethers.utils.arrayify(validator.previousSnapshot.pubKey.a)).to.deep.equal(new Uint8Array(32));
      expect(ethers.utils.arrayify(validator.previousSnapshot.pubKey.b)).to.deep.equal(new Uint8Array(32));
      expect(ethers.utils.arrayify(validator.previousSnapshot.pubKey.c)).to.deep.equal(new Uint8Array(32));
    }
  });

  it("Should not allow nonOwner to add", async function () {
    await expect(
      registry
        .connect(nonOwner)
        .add(
          ethers.Wallet.createRandom().address,
          0,
          { a: new Uint8Array(32), b: new Uint8Array(32), c: new Uint8Array(32) },
          { a: new Uint8Array(32), b: new Uint8Array(16) },
          { gasLimit }
        )
    ).to.be.reverted;
  });

  it("Should allow owner to deactivate", async function () {
    const validatorOwner = validatorEntries[0].ownerAddr;
    expect((await registry.validators(validatorOwner)).latest.active).to.equal(true);

    await (await registry.connect(owner).deactivate(validatorOwner, { gasLimit })).wait();
    expect((await registry.validators(validatorOwner)).latest.active).to.equal(false);

    // Restore state.
    await (await registry.connect(owner).activate(validatorOwner, { gasLimit })).wait();
  });

  it("Should not allow nonOwner, nonValidatorOwner to deactivate", async function () {
    const validatorOwner = validatorEntries[0].ownerAddr;
    await expect(registry.connect(nonOwner).deactivate(validatorOwner, { gasLimit })).to.be.reverted;
  });

  it("Should change validator weight", async function () {
    const entry = validatorEntries[0];
    expect((await registry.validators(entry.ownerAddr)).latest.weight).to.equal(entry.validatorWeight);

    const baseWeight = entry.validatorWeight;
    const newWeight = getRandomNumber(100, 1000);
    await (await registry.changeValidatorWeight(entry.ownerAddr, newWeight, { gasLimit })).wait();
    expect((await registry.validators(entry.ownerAddr)).latest.weight).to.equal(newWeight);

    // Restore state.
    await (await registry.changeValidatorWeight(entry.ownerAddr, baseWeight, { gasLimit })).wait();
  });

  it("Should not allow validatorOwner to change validator weight", async function () {
    const validator = validators[0];
    await expect(
      registry.connect(validator.ownerKey).changeValidatorWeight(validator.ownerKey.address, 0, { gasLimit })
    ).to.be.reverted;
  });

  it("Should not allow nonOwner to change validator weight", async function () {
    const validator = validators[0];
    await expect(registry.connect(nonOwner).changeValidatorWeight(validator.ownerKey.address, 0, { gasLimit })).to.be
      .reverted;
  });

  it("Should not allow to add a validator with a public key which already exists", async function () {
    const newEntry = makeRandomValidatorEntry(makeRandomValidator(), 0);
    await expect(
      registry.add(
        newEntry.ownerAddr,
        newEntry.validatorWeight,
        validatorEntries[0].validatorPubKey,
        newEntry.validatorPoP,
        { gasLimit }
      )
    ).to.be.reverted;
  });

  it("Should return validator committee once committed to", async function () {
    // Verify that committee was not committed to.
    expect((await registry.getValidatorCommittee()).length).to.equal(0);

    // Commit.
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();

    // Read committee.
    const validatorCommittee = await registry.getValidatorCommittee();
    expect(validatorCommittee.length).to.equal(validators.length);
    for (let i = 0; i < validatorCommittee.length; i++) {
      const entry = validatorEntries[i];
      const validator = validatorCommittee[i];
      expect(validator.weight).to.equal(entry.validatorWeight);
      expect(validator.pubKey.a).to.equal(entry.validatorPubKey.a);
      expect(validator.pubKey.b).to.equal(entry.validatorPubKey.b);
      expect(validator.pubKey.c).to.equal(entry.validatorPubKey.c);
      expect(validator.proofOfPossession.a).to.equal(entry.validatorPoP.a);
      expect(validator.proofOfPossession.b).to.equal(entry.validatorPoP.b);
    }
  });

  it("Should not include inactive validators in committee when committed to", async function () {
    const idx = validatorEntries.length - 1;
    const entry = validatorEntries[idx];

    // Deactivate attribute.
    await (await registry.deactivate(entry.ownerAddr, { gasLimit })).wait();

    // Verify no change.
    expect((await registry.getValidatorCommittee()).length).to.equal(validators.length);

    // Commit validator committee and verify.
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();
    expect((await registry.getValidatorCommittee()).length).to.equal(validators.length - 1);

    // Restore state.
    await (await registry.activate(entry.ownerAddr, { gasLimit })).wait();
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();
  });

  it("Should not include removed validators in committee when committed to", async function () {
    const idx = validatorEntries.length - 1;
    const entry = validatorEntries[idx];

    // Remove validator.
    await (await registry.remove(entry.ownerAddr, { gasLimit })).wait();

    // Verify no change.
    expect((await registry.getValidatorCommittee()).length).to.equal(validators.length);

    // Commit validator committee and verify.
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();
    expect((await registry.getValidatorCommittee()).length).to.equal(validators.length - 1);

    // Restore state.
    await (await registry.remove(entry.ownerAddr, { gasLimit })).wait();
    await (
      await registry.add(entry.ownerAddr, entry.validatorWeight, entry.validatorPubKey, entry.validatorPoP)
    ).wait();
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();
  });

  it("Should not include validator attribute change in committee before committed to", async function () {
    const idx = validatorEntries.length - 1;
    const entry = validatorEntries[idx];

    // Change attribute.
    await (await registry.changeValidatorWeight(entry.ownerAddr, entry.validatorWeight + 1, { gasLimit })).wait();

    // Verify no change.
    const validator = (await registry.getValidatorCommittee())[idx];
    expect(validator.weight).to.equal(entry.validatorWeight);

    // Commit.
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();

    // Verify change.
    const committedValidator = (await registry.getValidatorCommittee())[idx];
    expect(committedValidator.weight).to.equal(entry.validatorWeight + 1);

    // Restore state.
    await (await registry.changeValidatorWeight(entry.ownerAddr, entry.validatorWeight, { gasLimit })).wait();
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();
  });

  it("Should finalize validator removal by fully deleting it from storage", async function () {
    const idx = validatorEntries.length - 1;
    const entry = validatorEntries[idx];

    // Remove.
    expect((await registry.validators(entry.ownerAddr)).latest.removed).to.equal(false);
    await (await registry.remove(entry.ownerAddr, { gasLimit })).wait();
    expect((await registry.validators(entry.ownerAddr)).latest.removed).to.equal(true);

    // Commit committee.
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();

    // Verify validator was not yet deleted.
    expect(await registry.numValidators()).to.equal(validators.length);
    const validatorPubKeyHash = hashValidatorPubKey(entry.validatorPubKey);
    expect(await registry.validatorPubKeyHashes(validatorPubKeyHash)).to.be.equal(true);

    // Trigger validator deletion.
    await (await registry.remove(entry.ownerAddr, { gasLimit })).wait();

    // Verify the deletion.
    expect(await registry.numValidators()).to.equal(validators.length - 1);
    expect(await registry.validatorPubKeyHashes(validatorPubKeyHash)).to.be.equal(false);
    const validator = await registry.validators(entry.ownerAddr, { gasLimit });
    expect(ethers.utils.arrayify(validator.latest.pubKey.a)).to.deep.equal(new Uint8Array(32));
    expect(ethers.utils.arrayify(validator.latest.pubKey.b)).to.deep.equal(new Uint8Array(32));
    expect(ethers.utils.arrayify(validator.latest.pubKey.c)).to.deep.equal(new Uint8Array(32));

    // Restore state.
    await (
      await registry.add(entry.ownerAddr, entry.validatorWeight, entry.validatorPubKey, entry.validatorPoP)
    ).wait();
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();
  });

  it("Should set and respect committee activation delay", async function () {
    // Set delay
    const delay = 5;
    await (await registry.setCommitteeActivationDelay(delay, { gasLimit })).wait();

    // Make changes
    const idx = validatorEntries.length - 1;
    const entry = validatorEntries[idx];
    await (await registry.changeValidatorWeight(entry.ownerAddr, entry.validatorWeight + 10, { gasLimit })).wait();

    // Commit
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();

    // Attempting to commit again before delay passes should revert
    await expect(registry.commitValidatorCommittee({ gasLimit })).to.be.revertedWithCustomError(
      registry,
      "PreviousCommitStillPending"
    );

    // Should have a pending committee
    const pendingCommittee = await registry.getNextValidatorCommittee();
    expect(pendingCommittee[idx].weight).to.equal(entry.validatorWeight + 10);

    // Current committee should be unchanged until delay passes
    const currentCommittee = await registry.getValidatorCommittee();
    expect(currentCommittee[idx].weight).to.equal(entry.validatorWeight);

    // Restore state
    await (await registry.changeValidatorWeight(entry.ownerAddr, entry.validatorWeight, { gasLimit })).wait();
    await (await registry.setCommitteeActivationDelay(0, { gasLimit })).wait();
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();
  });

  it("Should activate pending committee after delay passes", async function () {
    // Set delay
    const delay = 5;
    await (await registry.setCommitteeActivationDelay(delay, { gasLimit })).wait();

    // Make changes to validator weight
    const idx = validatorEntries.length - 1;
    const entry = validatorEntries[idx];
    const newWeight = entry.validatorWeight + 20;
    await (await registry.changeValidatorWeight(entry.ownerAddr, newWeight, { gasLimit })).wait();

    // Commit to create pending committee
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();

    // Verify pending committee has new weight
    const pendingCommittee = await registry.getNextValidatorCommittee();
    expect(pendingCommittee[idx].weight).to.equal(newWeight);

    // Verify current committee still has old weight
    let currentCommittee = await registry.getValidatorCommittee();
    expect(currentCommittee[idx].weight).to.equal(entry.validatorWeight);

    // Mine blocks to pass the delay
    for (let i = 0; i < delay; i++) {
      await hre.network.provider.send("hardhat_mine", ["0x1"]);
    }

    // Trigger state update with a transaction
    await (
      await owner.sendTransaction({
        to: owner.address,
        value: 0,
      })
    ).wait();

    // Now pending committee should have become the active committee
    currentCommittee = await registry.getValidatorCommittee();
    expect(currentCommittee[idx].weight).to.equal(newWeight);

    // Restore state
    await (await registry.changeValidatorWeight(entry.ownerAddr, entry.validatorWeight, { gasLimit })).wait();
    await (await registry.setCommitteeActivationDelay(0, { gasLimit })).wait();
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();
  });

  function makeRandomValidator(provider?) {
    return {
      ownerKey: new Wallet(Wallet.createRandom().privateKey, provider),
      validatorKey: Wallet.createRandom(),
    };
  }

  function makeRandomValidatorEntry(validator, weight: number) {
    return {
      ownerAddr: validator.ownerKey.address,
      validatorWeight: weight,
      validatorPubKey: getRandomValidatorPubKey(),
      validatorPoP: getRandomValidatorPoP(),
    };
  }
});

function getRandomNumber(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function getRandomValidatorPubKey() {
  return {
    a: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
    b: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
    c: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
  };
}

function getRandomValidatorPoP() {
  return {
    a: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
    b: ethers.utils.hexlify(ethers.utils.randomBytes(16)),
  };
}

function hashValidatorPubKey(validatorPubKey) {
  return ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["bytes32", "bytes32", "bytes32"],
      [validatorPubKey.a, validatorPubKey.b, validatorPubKey.c]
    )
  );
}
