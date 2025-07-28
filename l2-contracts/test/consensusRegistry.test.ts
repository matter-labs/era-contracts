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

// Helper functions
function getRandomNumber(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}

function getRandomBoolean() {
  return Math.random() >= 0.5;
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
    validatorIsLeader: getRandomBoolean(),
    validatorIsActive: getRandomBoolean(),
    validatorPubKey: getRandomValidatorPubKey(),
    validatorPoP: getRandomValidatorPoP(),
  };
}

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

  describe("Initialization and Basic Setup", function () {
    it("Should set the owner as provided in constructor", async function () {
      expect(await registry.owner()).to.equal(owner.address);
    });

    it("Should have default leader selection configuration after initialization", async function () {
      const leaderSelection = await registry.leaderSelection();
      expect(leaderSelection.latest.frequency).to.equal(1);
      expect(leaderSelection.latest.weighted).to.equal(false);
    });
  });

  describe("Input Validation", function () {
    it("Should reject zero weight validator", async function () {
      const validEntry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await expect(
        registry.add(
          validEntry.ownerAddr,
          validEntry.validatorIsLeader,
          validEntry.validatorIsActive,
          0, // Zero weight
          validEntry.validatorPubKey,
          validEntry.validatorPoP,
          { gasLimit }
        )
      ).to.be.revertedWithCustomError(registry, "ZeroValidatorWeight");
    });

    it("Should reject empty BLS public key", async function () {
      const validEntry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      const emptyPubKey = { a: ethers.constants.HashZero, b: ethers.constants.HashZero, c: ethers.constants.HashZero };
      await expect(
        registry.add(
          validEntry.ownerAddr,
          validEntry.validatorIsLeader,
          validEntry.validatorIsActive,
          validEntry.validatorWeight,
          emptyPubKey,
          validEntry.validatorPoP,
          { gasLimit }
        )
      ).to.be.revertedWithCustomError(registry, "InvalidInputBLS12_381PublicKey");
    });

    it("Should reject empty BLS signature", async function () {
      const validEntry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      const emptyPoP = { a: ethers.constants.HashZero, b: "0x00000000000000000000000000000000" };
      await expect(
        registry.add(
          validEntry.ownerAddr,
          validEntry.validatorIsLeader,
          validEntry.validatorIsActive,
          validEntry.validatorWeight,
          validEntry.validatorPubKey,
          emptyPoP,
          { gasLimit }
        )
      ).to.be.revertedWithCustomError(registry, "InvalidInputBLS12_381Signature");
    });

    it("Should reject zero address as validator owner", async function () {
      const validEntry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await expect(
        registry.add(
          ethers.constants.AddressZero,
          validEntry.validatorIsLeader,
          validEntry.validatorIsActive,
          validEntry.validatorWeight,
          validEntry.validatorPubKey,
          validEntry.validatorPoP,
          { gasLimit }
        )
      ).to.be.revertedWithCustomError(registry, "InvalidInputValidatorOwnerAddress");
    });

    it("Should reject partially empty BLS public key", async function () {
      const validEntry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      const partialPubKey = {
        a: validEntry.validatorPubKey.a,
        b: ethers.constants.HashZero,
        c: validEntry.validatorPubKey.c
      };
      await expect(
        registry.add(
          validEntry.ownerAddr,
          validEntry.validatorIsLeader,
          validEntry.validatorIsActive,
          validEntry.validatorWeight,
          partialPubKey,
          validEntry.validatorPoP,
          { gasLimit }
        )
      ).to.be.revertedWithCustomError(registry, "InvalidInputBLS12_381PublicKey");
    });

    it("Should reject partially empty BLS signature", async function () {
      const validEntry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      const partialPoP = { a: ethers.constants.HashZero, b: validEntry.validatorPoP.b };
      await expect(
        registry.add(
          validEntry.ownerAddr,
          validEntry.validatorIsLeader,
          validEntry.validatorIsActive,
          validEntry.validatorWeight,
          validEntry.validatorPubKey,
          partialPoP,
          { gasLimit }
        )
      ).to.be.revertedWithCustomError(registry, "InvalidInputBLS12_381Signature");
    });

    it("Should reject zero weight when changing validator weight", async function () {
      // First add a validator (using valid weight)
      const validEntry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        validEntry.ownerAddr,
        validEntry.validatorIsLeader,
        validEntry.validatorIsActive,
        validEntry.validatorWeight,
        validEntry.validatorPubKey,
        validEntry.validatorPoP
      )).wait();

      // Then try to change weight to zero
      await expect(
        registry.changeValidatorWeight(validEntry.ownerAddr, 0, { gasLimit })
      ).to.be.revertedWithCustomError(registry, "ZeroValidatorWeight");
    });

    it("Should reject empty BLS public key when changing validator key", async function () {
      // First add a validator
      const validEntry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        validEntry.ownerAddr,
        validEntry.validatorIsLeader,
        validEntry.validatorIsActive,
        validEntry.validatorWeight,
        validEntry.validatorPubKey,
        validEntry.validatorPoP
      )).wait();

      const emptyPubKey = { a: ethers.constants.HashZero, b: ethers.constants.HashZero, c: ethers.constants.HashZero };
      await expect(
        registry.changeValidatorKey(validEntry.ownerAddr, emptyPubKey, validEntry.validatorPoP, { gasLimit })
      ).to.be.revertedWithCustomError(registry, "InvalidInputBLS12_381PublicKey");
    });

    it("Should reject empty BLS signature when changing validator key", async function () {
      // First add a validator
      const validEntry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        validEntry.ownerAddr,
        validEntry.validatorIsLeader,
        validEntry.validatorIsActive,
        validEntry.validatorWeight,
        validEntry.validatorPubKey,
        validEntry.validatorPoP
      )).wait();

      const emptyPoP = { a: ethers.constants.HashZero, b: "0x00000000000000000000000000000000" };
      await expect(
        registry.changeValidatorKey(validEntry.ownerAddr, validEntry.validatorPubKey, emptyPoP, { gasLimit })
      ).to.be.revertedWithCustomError(registry, "InvalidInputBLS12_381Signature");
    });

    it("Should reject operations on non-existent validators", async function () {
      const nonExistentAddr = ethers.Wallet.createRandom().address;

      await expect(
        registry.changeValidatorActive(nonExistentAddr, false, { gasLimit })
      ).to.be.revertedWithCustomError(registry, "ValidatorOwnerDoesNotExist");

      await expect(
        registry.changeValidatorWeight(nonExistentAddr, 100, { gasLimit })
      ).to.be.revertedWithCustomError(registry, "ValidatorOwnerDoesNotExist");

      await expect(
        registry.changeValidatorLeader(nonExistentAddr, true, { gasLimit })
      ).to.be.revertedWithCustomError(registry, "ValidatorOwnerDoesNotExist");

      const validEntry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await expect(
        registry.changeValidatorKey(nonExistentAddr, validEntry.validatorPubKey, validEntry.validatorPoP, { gasLimit })
      ).to.be.revertedWithCustomError(registry, "ValidatorOwnerDoesNotExist");

      await expect(
        registry.remove(nonExistentAddr, { gasLimit })
      ).to.be.revertedWithCustomError(registry, "ValidatorOwnerDoesNotExist");
    });
  });

  describe("Event Emissions", function () {
    it("Should emit ValidatorAdded event with correct parameters", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await expect(
        registry.add(
          entry.ownerAddr,
          entry.validatorIsLeader,
          entry.validatorIsActive,
          entry.validatorWeight,
          entry.validatorPubKey,
          entry.validatorPoP
        )
      ).to.emit(registry, "ValidatorAdded")
        .withArgs(
          entry.ownerAddr,
          entry.validatorIsActive,
          entry.validatorIsLeader,
          entry.validatorWeight,
          [entry.validatorPubKey.a, entry.validatorPubKey.b, entry.validatorPubKey.c]
        );
    });

    it("Should emit ValidatorRemoved event", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        entry.ownerAddr,
        entry.validatorIsLeader,
        entry.validatorIsActive,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      await expect(
        registry.remove(entry.ownerAddr)
      ).to.emit(registry, "ValidatorRemoved")
        .withArgs(entry.ownerAddr);
    });

    it("Should emit ValidatorDeleted event when validator is fully deleted", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        entry.ownerAddr,
        entry.validatorIsLeader,
        entry.validatorIsActive,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      // Remove and commit to make it eligible for deletion
      await (await registry.remove(entry.ownerAddr)).wait();
      await (await registry.commitValidatorCommittee()).wait();

      // Second remove should trigger deletion
      await expect(
        registry.remove(entry.ownerAddr)
      ).to.emit(registry, "ValidatorDeleted")
        .withArgs(entry.ownerAddr);
    });

    it("Should emit ValidatorActiveStatusChanged event", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        entry.ownerAddr,
        entry.validatorIsLeader,
        true, // Start as active
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      await expect(
        registry.changeValidatorActive(entry.ownerAddr, false)
      ).to.emit(registry, "ValidatorActiveStatusChanged")
        .withArgs(entry.ownerAddr, false);

      await expect(
        registry.changeValidatorActive(entry.ownerAddr, true)
      ).to.emit(registry, "ValidatorActiveStatusChanged")
        .withArgs(entry.ownerAddr, true);
    });

    it("Should emit ValidatorLeaderStatusChanged event", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        entry.ownerAddr,
        false, // Start as non-leader
        entry.validatorIsActive,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      await expect(
        registry.changeValidatorLeader(entry.ownerAddr, true)
      ).to.emit(registry, "ValidatorLeaderStatusChanged")
        .withArgs(entry.ownerAddr, true);

      await expect(
        registry.changeValidatorLeader(entry.ownerAddr, false)
      ).to.emit(registry, "ValidatorLeaderStatusChanged")
        .withArgs(entry.ownerAddr, false);
    });

    it("Should emit ValidatorWeightChanged event", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        entry.ownerAddr,
        entry.validatorIsLeader,
        entry.validatorIsActive,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      const newWeight = 200;
      await expect(
        registry.changeValidatorWeight(entry.ownerAddr, newWeight)
      ).to.emit(registry, "ValidatorWeightChanged")
        .withArgs(entry.ownerAddr, newWeight);
    });

    it("Should emit ValidatorKeyChanged event", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        entry.ownerAddr,
        entry.validatorIsLeader,
        entry.validatorIsActive,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      const newKey = getRandomValidatorPubKey();
      const newPoP = getRandomValidatorPoP();
      await expect(
        registry.changeValidatorKey(entry.ownerAddr, newKey, newPoP)
      ).to.emit(registry, "ValidatorKeyChanged")
        .withArgs(entry.ownerAddr, [newKey.a, newKey.b, newKey.c]);
    });

    it("Should emit ValidatorsCommitted event", async function () {
      // First add a validator to avoid NoActiveLeader error
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        entry.ownerAddr,
        true, // Make it a leader
        true, // Make it active
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      const tx = await registry.commitValidatorCommittee();
      const receipt = await tx.wait();
      const currentBlock = receipt.blockNumber;

      await expect(tx)
        .to.emit(registry, "ValidatorsCommitted")
        .withArgs(1, currentBlock); // First commit should have commit number 1
    });

    it("Should emit CommitteeActivationDelayChanged event", async function () {
      const newDelay = 10;
      await expect(
        registry.setCommitteeActivationDelay(newDelay)
      ).to.emit(registry, "CommitteeActivationDelayChanged")
        .withArgs(newDelay);
    });

    it("Should emit LeaderSelectionChanged event", async function () {
      const newFrequency = 5;
      const newWeighted = true;
      await expect(
        registry.updateLeaderSelection(newFrequency, newWeighted)
      ).to.emit(registry, "LeaderSelectionChanged")
        .withArgs([newFrequency, newWeighted]);
    });
  });

  describe("Authorization and Access Control", function () {
    it("Should not allow validatorOwner to add", async function () {
      await expect(
        registry
          .connect(validators[0].ownerKey)
          .add(
            ethers.Wallet.createRandom().address,
            true,
            true,
            0,
            { a: new Uint8Array(32), b: new Uint8Array(32), c: new Uint8Array(32) },
            { a: new Uint8Array(32), b: new Uint8Array(16) },
            { gasLimit }
          )
      ).to.be.reverted;
    });

    it("Should not allow validatorOwner to change validator weight", async function () {
      const validator = validators[0];
      await expect(
        registry.connect(validator.ownerKey).changeValidatorWeight(validator.ownerKey.address, 0, { gasLimit })
      ).to.be.reverted;
    });

    it("Should not allow validatorOwner to change validator leader status", async function () {
      const validator = validators[0];
      await expect(
        registry.connect(validator.ownerKey).changeValidatorLeader(validator.ownerKey.address, true, { gasLimit })
      ).to.be.reverted;
    });

    it("Should not allow nonOwner to change validator active status", async function () {
      const validatorOwner = validatorEntries[0].ownerAddr;
      await expect(registry.connect(nonOwner).changeValidatorActive(validatorOwner, false, { gasLimit })).to.be.reverted;
    });

    it("Should not allow nonOwner to change validator public key", async function () {
      const validator = makeRandomValidatorEntry(makeRandomValidator(), 0);
      await expect(
        registry
          .connect(nonOwner)
          .changeValidatorKey(validator.ownerAddr, validator.validatorPubKey, validator.validatorPoP, { gasLimit })
      ).to.be.reverted;
    });

    it("Should not allow validatorOwner to change their own validator key", async function () {
      const validator = validators[0];
      const validEntry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await expect(
        registry
          .connect(validator.ownerKey)
          .changeValidatorKey(validator.ownerKey.address, validEntry.validatorPubKey, validEntry.validatorPoP, { gasLimit })
      ).to.be.reverted;
    });

    it("Should not allow validatorOwner to update leader selection", async function () {
      await expect(registry.connect(validators[0].ownerKey).updateLeaderSelection(5, true, { gasLimit })).to.be.reverted;
    });
  });

  describe("Basic Validator Operations", function () {
    it("Should add validators to registry", async function () {
      for (let i = 0; i < validators.length; i++) {
        await (
          await registry.add(
            validatorEntries[i].ownerAddr,
            validatorEntries[i].validatorIsLeader,
            validatorEntries[i].validatorIsActive,
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

    it("Should not allow to add a validator with a public key which already exists", async function () {
      const newEntry = makeRandomValidatorEntry(makeRandomValidator(), 0);
      await expect(
        registry.add(
          newEntry.ownerAddr,
          newEntry.validatorIsLeader,
          newEntry.validatorIsActive,
          newEntry.validatorWeight,
          validatorEntries[0].validatorPubKey,
          newEntry.validatorPoP,
          { gasLimit }
        )
      ).to.be.reverted;
    });

    it("Should not allow to add a validator with an owner address which already exists", async function () {
      const newEntry = makeRandomValidatorEntry(makeRandomValidator(), 0);
      await expect(
        registry.add(
          validatorEntries[0].ownerAddr, // Using an existing owner address
          newEntry.validatorIsLeader,
          newEntry.validatorIsActive,
          newEntry.validatorWeight,
          newEntry.validatorPubKey,
          newEntry.validatorPoP,
          { gasLimit }
        )
      ).to.be.reverted;
    });

    it("Should change validator active status", async function () {
      const validatorOwner = validatorEntries[0].ownerAddr;
      expect((await registry.validators(validatorOwner)).latest.active).to.equal(true);

      // Deactivate
      await (await registry.connect(validatorOwner).changeValidatorActive(validatorOwner, false, { gasLimit })).wait();
      expect((await registry.validators(validatorOwner)).latest.active).to.equal(false);

      // Activate
      await (await registry.connect(validatorOwner).changeValidatorActive(validatorOwner, true, { gasLimit })).wait();
      expect((await registry.validators(validatorOwner)).latest.active).to.equal(true);
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

    it("Should change validator leader status", async function () {
      const entry = validatorEntries[0];
      // By default leader should be true.
      const initialLeaderStatus = (await registry.validators(entry.ownerAddr)).latest["leader"];

      // Change to the opposite status
      await (await registry.changeValidatorLeader(entry.ownerAddr, !initialLeaderStatus, { gasLimit })).wait();
      expect((await registry.validators(entry.ownerAddr)).latest["leader"]).to.equal(!initialLeaderStatus);

      // Change back to original status
      await (await registry.changeValidatorLeader(entry.ownerAddr, initialLeaderStatus, { gasLimit })).wait();
      expect((await registry.validators(entry.ownerAddr)).latest["leader"]).to.equal(initialLeaderStatus);
    });

    it("Should change validator public key", async function () {
      const entry = validatorEntries[0];
      const newEntry = makeRandomValidatorEntry(makeRandomValidator(), 0);

      // Change public key.
      await (
        await registry.changeValidatorKey(entry.ownerAddr, newEntry.validatorPubKey, newEntry.validatorPoP, { gasLimit })
      ).wait();
      expect((await registry.validators(entry.ownerAddr)).latest.pubKey.a).to.equal(newEntry.validatorPubKey.a);

      // Restore state.
      await (
        await registry.changeValidatorKey(entry.ownerAddr, entry.validatorPubKey, entry.validatorPoP, { gasLimit })
      ).wait();
      expect((await registry.validators(entry.ownerAddr)).latest.pubKey.a).to.equal(entry.validatorPubKey.a);
    });
  });

  describe("Validator Removal and Cleanup", function () {
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
        await registry.add(
          entry.ownerAddr,
          entry.validatorIsLeader,
          entry.validatorIsActive,
          entry.validatorWeight,
          entry.validatorPubKey,
          entry.validatorPoP
        )
      ).wait();
      await (await registry.commitValidatorCommittee({ gasLimit })).wait();
    });
  });

  describe("Re-adding Removed Validators", function () {
    it("Should allow re-adding a removed validator with same public key", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);

      // Add validator initially
      await (await registry.add(
        entry.ownerAddr,
        entry.validatorIsLeader,
        entry.validatorIsActive,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      // Remove validator
      await (await registry.remove(entry.ownerAddr)).wait();
      expect((await registry.validators(entry.ownerAddr)).latest.removed).to.equal(true);

      // Re-add same validator with same key
      await (await registry.add(
        entry.ownerAddr,
        entry.validatorIsLeader,
        entry.validatorIsActive,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      // Verify it was re-added successfully
      const validator = await registry.validators(entry.ownerAddr);
      expect(validator.latest.removed).to.equal(false);
      expect(validator.latest.active).to.equal(entry.validatorIsActive);
      expect(validator.latest.weight).to.equal(entry.validatorWeight);
    });

    it("Should allow re-adding removed validator with different public key", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);

      // Add validator initially
      await (await registry.add(
        entry.ownerAddr,
        entry.validatorIsLeader,
        entry.validatorIsActive,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      // Remove validator
      await (await registry.remove(entry.ownerAddr)).wait();

      // Create new key
      const newPubKey = getRandomValidatorPubKey();
      const newPoP = getRandomValidatorPoP();

      // Re-add with different key
      await (await registry.add(
        entry.ownerAddr,
        !entry.validatorIsLeader, // Change leader status too
        !entry.validatorIsActive, // Change active status too
        entry.validatorWeight + 50, // Change weight too
        newPubKey,
        newPoP
      )).wait();

      // Verify new attributes
      const validator = await registry.validators(entry.ownerAddr);
      expect(validator.latest.removed).to.equal(false);
      expect(validator.latest.leader).to.equal(!entry.validatorIsLeader);
      expect(validator.latest.active).to.equal(!entry.validatorIsActive);
      expect(validator.latest.weight).to.equal(entry.validatorWeight + 50);
      expect(validator.latest.pubKey.a).to.equal(newPubKey.a);
      expect(validator.latest.pubKey.b).to.equal(newPubKey.b);
      expect(validator.latest.pubKey.c).to.equal(newPubKey.c);

      // Verify old key hash was removed and new one added
      const oldHash = hashValidatorPubKey(entry.validatorPubKey);
      const newHash = hashValidatorPubKey(newPubKey);
      expect(await registry.validatorPubKeyHashes(oldHash)).to.equal(false);
      expect(await registry.validatorPubKeyHashes(newHash)).to.equal(true);
    });

    it("Should not allow re-adding removed validator with existing public key", async function () {
      const entry1 = makeRandomValidatorEntry(makeRandomValidator(), 100);
      const entry2 = makeRandomValidatorEntry(makeRandomValidator(), 200);

      // Add two validators
      await (await registry.add(
        entry1.ownerAddr,
        entry1.validatorIsLeader,
        entry1.validatorIsActive,
        entry1.validatorWeight,
        entry1.validatorPubKey,
        entry1.validatorPoP
      )).wait();

      await (await registry.add(
        entry2.ownerAddr,
        entry2.validatorIsLeader,
        entry2.validatorIsActive,
        entry2.validatorWeight,
        entry2.validatorPubKey,
        entry2.validatorPoP
      )).wait();

      // Remove first validator
      await (await registry.remove(entry1.ownerAddr)).wait();

      // Try to re-add first validator with second validator's key
      await expect(
        registry.add(
          entry1.ownerAddr,
          entry1.validatorIsLeader,
          entry1.validatorIsActive,
          entry1.validatorWeight,
          entry2.validatorPubKey, // Using existing key
          entry1.validatorPoP
        )
      ).to.be.revertedWithCustomError(registry, "ValidatorPubKeyExists");
    });

    it("Should properly clean up removed validator from removedValidators array when re-added", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);

      // Add validator
      await (await registry.add(
        entry.ownerAddr,
        entry.validatorIsLeader,
        entry.validatorIsActive,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      // Check initial removed validators count
      const initialCount = await registry.numRemovedValidators();

      // Remove validator
      await (await registry.remove(entry.ownerAddr)).wait();

      // Check removed validators count increased
      expect(await registry.numRemovedValidators()).to.equal(initialCount.add(1));

      // Re-add validator
      await (await registry.add(
        entry.ownerAddr,
        entry.validatorIsLeader,
        entry.validatorIsActive,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      // Check removed validators count decreased back
      expect(await registry.numRemovedValidators()).to.equal(initialCount);
    });

    it("Should not allow re-adding if validator is not removed", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);

      // Add validator initially
      await (await registry.add(
        entry.ownerAddr,
        entry.validatorIsLeader,
        entry.validatorIsActive,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      // Try to add again without removing (should fail with ValidatorOwnerExists)
      await expect(
        registry.add(
          entry.ownerAddr,
          entry.validatorIsLeader,
          entry.validatorIsActive,
          entry.validatorWeight,
          entry.validatorPubKey,
          entry.validatorPoP
        )
      ).to.be.revertedWithCustomError(registry, "ValidatorOwnerExists");
    });
  });

  describe("Committee Management", function () {
    it("Should return validator committee once committed to", async function () {
      // Verify that committee was not committed to.
      const [initialCommittee, initialLeaderSelection] = await registry.getValidatorCommittee();
      expect(initialCommittee.length).to.equal(0);
      expect(initialLeaderSelection.frequency).to.equal(1);
      expect(initialLeaderSelection.weighted).to.equal(false);

      // Commit.
      await (await registry.commitValidatorCommittee({ gasLimit })).wait();

      // Read committee.
      const [validatorCommittee, leaderSelection] = await registry.getValidatorCommittee();
      expect(validatorCommittee.length).to.equal(validators.length);
      expect(leaderSelection.frequency).to.equal(1);
      expect(leaderSelection.weighted).to.equal(false);
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

      // Deactivate validator.
      await (await registry.changeValidatorActive(entry.ownerAddr, false, { gasLimit })).wait();

      // Verify no change.
      const [currentCommittee] = await registry.getValidatorCommittee();
      expect(currentCommittee.length).to.equal(validators.length);

      // Commit validator committee and verify.
      await (await registry.commitValidatorCommittee({ gasLimit })).wait();
      const [newCommittee] = await registry.getValidatorCommittee();
      expect(newCommittee.length).to.equal(validators.length - 1);

      // Restore state.
      await (await registry.changeValidatorActive(entry.ownerAddr, true, { gasLimit })).wait();
      await (await registry.commitValidatorCommittee({ gasLimit })).wait();
    });

    it("Should not include removed validators in committee when committed to", async function () {
      const idx = validatorEntries.length - 1;
      const entry = validatorEntries[idx];

      // Remove validator.
      await (await registry.remove(entry.ownerAddr, { gasLimit })).wait();

      // Verify no change.
      const [currentCommittee] = await registry.getValidatorCommittee();
      expect(currentCommittee.length).to.equal(validators.length);

      // Commit validator committee and verify.
      await (await registry.commitValidatorCommittee({ gasLimit })).wait();
      const [newCommittee] = await registry.getValidatorCommittee();
      expect(newCommittee.length).to.equal(validators.length - 1);

      // Restore state.
      await (await registry.remove(entry.ownerAddr, { gasLimit })).wait();
      await (
        await registry.add(
          entry.ownerAddr,
          entry.validatorIsLeader,
          entry.validatorIsActive,
          entry.validatorWeight,
          entry.validatorPubKey,
          entry.validatorPoP
        )
      ).wait();
      await (await registry.commitValidatorCommittee({ gasLimit })).wait();
    });

    it("Should not allow committing validator committee with no active leader", async function () {
      // First, make sure all validators have leader=false
      for (let i = 0; i < validatorEntries.length; i++) {
        await (await registry.changeValidatorLeader(validatorEntries[i].ownerAddr, false, { gasLimit })).wait();
      }

      // Trying to commit should now fail with NoActiveLeader error
      await expect(registry.commitValidatorCommittee({ gasLimit })).to.be.revertedWithCustomError(
        registry,
        "NoActiveLeader"
      );

      // Set at least one validator as leader to restore state
      await (await registry.changeValidatorLeader(validatorEntries[0].ownerAddr, true, { gasLimit })).wait();

      // Now the commit should succeed
      await (await registry.commitValidatorCommittee({ gasLimit })).wait();
    });

    it("Should not include validator attribute change in committee before committed to", async function () {
      const idx = validatorEntries.length - 1;
      const entry = validatorEntries[idx];

      // Change attribute.
      await (await registry.changeValidatorWeight(entry.ownerAddr, entry.validatorWeight + 1, { gasLimit })).wait();

      // Verify no change.
      const [validatorCommittee] = await registry.getValidatorCommittee();
      const validator = validatorCommittee[idx];
      expect(validator.weight).to.equal(entry.validatorWeight);

      // Commit.
      await (await registry.commitValidatorCommittee({ gasLimit })).wait();

      // Verify change.
      const [newValidatorCommittee] = await registry.getValidatorCommittee();
      const committedValidator = newValidatorCommittee[idx];
      expect(committedValidator.weight).to.equal(entry.validatorWeight + 1);

      // Restore state.
      await (await registry.changeValidatorWeight(entry.ownerAddr, entry.validatorWeight, { gasLimit })).wait();
      await (await registry.commitValidatorCommittee({ gasLimit })).wait();
    });
  });

  describe("Cleanup Functionality and Edge Cases", function () {
    it("Should manually cleanup removed validators", async function () {
      const entries = [];
      // Add multiple validators
      for (let i = 0; i < 3; i++) {
        const entry = makeRandomValidatorEntry(makeRandomValidator(), 100 + i);
        entries.push(entry);
        await (await registry.add(
          entry.ownerAddr,
          entry.validatorIsLeader,
          entry.validatorIsActive,
          entry.validatorWeight,
          entry.validatorPubKey,
          entry.validatorPoP
        )).wait();
      }

      // Remove all validators
      for (const entry of entries) {
        await (await registry.remove(entry.ownerAddr)).wait();
      }

      // Commit to make them eligible for deletion
      await (await registry.commitValidatorCommittee()).wait();

      const initialCount = await registry.numRemovedValidators();
      expect(initialCount).to.be.greaterThan(0);

      // Manually trigger cleanup
      await (await registry.cleanupRemovedValidators(2)).wait();

      // Check that some validators were cleaned up
      const afterCleanupCount = await registry.numRemovedValidators();
      expect(afterCleanupCount).to.be.lessThan(initialCount);
    });

    it("Should handle cleanup when no validators are eligible for deletion", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        entry.ownerAddr,
        entry.validatorIsLeader,
        entry.validatorIsActive,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      // Remove but don't commit (not eligible for deletion yet)
      await (await registry.remove(entry.ownerAddr)).wait();

      const beforeCleanup = await registry.numRemovedValidators();

      // Try cleanup - should not delete anything
      await (await registry.cleanupRemovedValidators(10)).wait();

      const afterCleanup = await registry.numRemovedValidators();
      expect(afterCleanup).to.equal(beforeCleanup);
    });

    it("Should handle getNextValidatorCommittee when no pending committee exists", async function () {
      // Ensure no pending committee by committing and letting it activate
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        entry.ownerAddr,
        true, // Make it a leader
        true, // Make it active
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      await (await registry.commitValidatorCommittee()).wait();

      // Now there's no pending committee, so this should revert
      await expect(registry.getNextValidatorCommittee())
        .to.be.revertedWithCustomError(registry, "NoPendingCommittee");
    });

    it("Should handle validator operations when validator is pending deletion", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        entry.ownerAddr,
        entry.validatorIsLeader,
        entry.validatorIsActive,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      // Remove and commit to make eligible for deletion
      await (await registry.remove(entry.ownerAddr)).wait();
      await (await registry.commitValidatorCommittee()).wait();

      // Operations on pending deletion validator should trigger deletion and return early
      const initialCount = await registry.numValidators();

      // This should delete the validator and return early
      await (await registry.changeValidatorActive(entry.ownerAddr, false)).wait();

      expect(await registry.numValidators()).to.equal(initialCount.sub(1));
    });

    it("Should correctly handle multiple snapshot generations", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        entry.ownerAddr,
        true, // Start as leader
        true, // Start as active  
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      // Make first change and commit
      await (await registry.changeValidatorWeight(entry.ownerAddr, 200)).wait();
      await (await registry.commitValidatorCommittee()).wait();

      let validator = await registry.validators(entry.ownerAddr);
      expect(validator.snapshot.weight).to.equal(200);

      // Make second change and commit
      await (await registry.changeValidatorWeight(entry.ownerAddr, 300)).wait();
      await (await registry.commitValidatorCommittee()).wait();

      validator = await registry.validators(entry.ownerAddr);
      expect(validator.snapshot.weight).to.equal(300);
      expect(validator.previousSnapshot.weight).to.equal(200);

      // Make third change and commit
      await (await registry.changeValidatorWeight(entry.ownerAddr, 400)).wait();
      await (await registry.commitValidatorCommittee()).wait();

      validator = await registry.validators(entry.ownerAddr);
      expect(validator.snapshot.weight).to.equal(400);
      expect(validator.previousSnapshot.weight).to.equal(300);
      // The first snapshot (200) should be lost now
    });

    it("Should handle changing validator key to same key (no-op)", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        entry.ownerAddr,
        entry.validatorIsLeader,
        entry.validatorIsActive,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      // Change key to same key - should be a no-op
      await (await registry.changeValidatorKey(
        entry.ownerAddr,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      // Verify nothing changed
      const validator = await registry.validators(entry.ownerAddr);
      expect(validator.latest.pubKey.a).to.equal(entry.validatorPubKey.a);
      expect(validator.latest.pubKey.b).to.equal(entry.validatorPubKey.b);
      expect(validator.latest.pubKey.c).to.equal(entry.validatorPubKey.c);
    });

    it("Should handle changing validator status to same value (no-op)", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        entry.ownerAddr,
        true, // Start as leader
        true, // Start as active
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      const initialLeaderCount = await registry.activeLeaderValidatorsCount();

      // Change active status to same value - should be no-op
      await (await registry.changeValidatorActive(entry.ownerAddr, true)).wait();
      expect(await registry.activeLeaderValidatorsCount()).to.equal(initialLeaderCount);

      // Change leader status to same value - should be no-op
      await (await registry.changeValidatorLeader(entry.ownerAddr, true)).wait();
      expect(await registry.activeLeaderValidatorsCount()).to.equal(initialLeaderCount);
    });

    it("Should correctly update activeLeaderValidatorsCount", async function () {
      const entry1 = makeRandomValidatorEntry(makeRandomValidator(), 100);
      const entry2 = makeRandomValidatorEntry(makeRandomValidator(), 200);

      // Add two active leaders
      await (await registry.add(entry1.ownerAddr, true, true, entry1.validatorWeight, entry1.validatorPubKey, entry1.validatorPoP)).wait();
      await (await registry.add(entry2.ownerAddr, true, true, entry2.validatorWeight, entry2.validatorPubKey, entry2.validatorPoP)).wait();

      expect(await registry.activeLeaderValidatorsCount()).to.equal(2);

      // Deactivate one leader
      await (await registry.changeValidatorActive(entry1.ownerAddr, false)).wait();
      expect(await registry.activeLeaderValidatorsCount()).to.equal(1);

      // Remove the other leader
      await (await registry.remove(entry2.ownerAddr)).wait();
      expect(await registry.activeLeaderValidatorsCount()).to.equal(0);

      // Reactivate first leader
      await (await registry.changeValidatorActive(entry1.ownerAddr, true)).wait();
      expect(await registry.activeLeaderValidatorsCount()).to.equal(1);

      // Change leader status of active validator
      await (await registry.changeValidatorLeader(entry1.ownerAddr, false)).wait();
      expect(await registry.activeLeaderValidatorsCount()).to.equal(0);
    });
  });

  describe("Committee Activation Delay", function () {
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
      const [pendingCommittee] = await registry.getNextValidatorCommittee();
      expect(pendingCommittee[idx].weight).to.equal(entry.validatorWeight + 10);

      // Current committee should be unchanged until delay passes
      const [currentCommittee] = await registry.getValidatorCommittee();
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

      // Get initial leader selection configuration
      const leaderInfo = await registry.leaderSelection();
      const initialFrequency = leaderInfo.latest.frequency;
      const initialWeighted = leaderInfo.latest.weighted;

      // Make changes to validator weight
      const idx = validatorEntries.length - 1;
      const entry = validatorEntries[idx];
      const newWeight = entry.validatorWeight + 20;
      await (await registry.changeValidatorWeight(entry.ownerAddr, newWeight, { gasLimit })).wait();

      // Also update leader selection
      const newFrequency = initialFrequency + 5;
      const newWeighted = !initialWeighted;
      await (await registry.updateLeaderSelection(newFrequency, newWeighted, { gasLimit })).wait();

      // Commit to create pending committee
      await (await registry.commitValidatorCommittee({ gasLimit })).wait();

      // Verify pending committee has new weight and leader selection
      const [pendingCommittee, pendingLeaderSelection] = await registry.getNextValidatorCommittee();
      expect(pendingCommittee[idx].weight).to.equal(newWeight);
      expect(pendingLeaderSelection.frequency).to.equal(newFrequency);
      expect(pendingLeaderSelection.weighted).to.equal(newWeighted);

      // Verify current committee still has old weight and leader selection
      let [currentCommittee, currentLeaderSelection] = await registry.getValidatorCommittee();
      expect(currentCommittee[idx].weight).to.equal(entry.validatorWeight);
      expect(currentLeaderSelection.frequency).to.equal(initialFrequency);
      expect(currentLeaderSelection.weighted).to.equal(initialWeighted);

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

      // Now pending committee should have become the active committee with new leader selection
      [currentCommittee, currentLeaderSelection] = await registry.getValidatorCommittee();
      expect(currentCommittee[idx].weight).to.equal(newWeight);
      expect(currentLeaderSelection.frequency).to.equal(newFrequency);
      expect(currentLeaderSelection.weighted).to.equal(newWeighted);

      // Restore state
      await (await registry.changeValidatorWeight(entry.ownerAddr, entry.validatorWeight, { gasLimit })).wait();
      await (await registry.updateLeaderSelection(initialFrequency, initialWeighted, { gasLimit })).wait();
      await (await registry.setCommitteeActivationDelay(0, { gasLimit })).wait();
      await (await registry.commitValidatorCommittee({ gasLimit })).wait();
    });
  });

  describe("Leader Selection Management", function () {
    it("Should update leader selection configuration", async function () {
      // Get initial configuration
      const initialConfig = await registry.leaderSelection();

      // Change to new values
      const newFrequency = 10;
      const newWeighted = true;
      await (await registry.updateLeaderSelection(newFrequency, newWeighted, { gasLimit })).wait();

      // Verify changes
      const updatedConfig = await registry.leaderSelection();
      expect(updatedConfig.latest.frequency).to.equal(newFrequency);
      expect(updatedConfig.latest.weighted).to.equal(newWeighted);

      // Reset to original values
      await (
        await registry.updateLeaderSelection(initialConfig.latest.frequency, initialConfig.latest.weighted, { gasLimit })
      ).wait();
    });

    it("Should snapshot leader selection configuration on commit", async function () {
      // Initial state
      let leaderSelection = await registry.leaderSelection();
      const initialFrequency = leaderSelection.latest.frequency;
      const initialWeighted = leaderSelection.latest.weighted;

      // Update leader selection
      const newFrequency = 20;
      const newWeighted = !initialWeighted;
      await (await registry.updateLeaderSelection(newFrequency, newWeighted, { gasLimit })).wait();

      // Commit
      await (await registry.commitValidatorCommittee({ gasLimit })).wait();

      // Check snapshot was created
      leaderSelection = await registry.leaderSelection();
      expect(leaderSelection.lastSnapshotCommit).to.be.greaterThan(0);
      expect(leaderSelection.snapshot.frequency).to.equal(newFrequency);
      expect(leaderSelection.snapshot.weighted).to.equal(newWeighted);

      // Update again to test multiple snapshots
      const newerFrequency = 30;
      const newerWeighted = !newWeighted;
      await (await registry.updateLeaderSelection(newerFrequency, newerWeighted, { gasLimit })).wait();

      // Commit again
      await (await registry.commitValidatorCommittee({ gasLimit })).wait();

      // Verify previous snapshot is preserved
      leaderSelection = await registry.leaderSelection();
      expect(leaderSelection.previousSnapshotCommit).to.be.greaterThan(0);
      expect(leaderSelection.previousSnapshot.frequency).to.equal(newFrequency);
      expect(leaderSelection.previousSnapshot.weighted).to.equal(newWeighted);
      expect(leaderSelection.snapshot.frequency).to.equal(newerFrequency);
      expect(leaderSelection.snapshot.weighted).to.equal(newerWeighted);

      // Reset to original values
      await (await registry.updateLeaderSelection(initialFrequency, initialWeighted, { gasLimit })).wait();
      await (await registry.commitValidatorCommittee({ gasLimit })).wait();
    });

    it("Should handle leader selection with frequency = 0", async function () {
      const initialConfig = await registry.leaderSelection();

      // Set frequency to 0 (leader never rotates)
      await (await registry.updateLeaderSelection(0, false, { gasLimit })).wait();

      const updatedConfig = await registry.leaderSelection();
      expect(updatedConfig.latest.frequency).to.equal(0);
      expect(updatedConfig.latest.weighted).to.equal(false);

      // Reset to original values
      await (await registry.updateLeaderSelection(initialConfig.latest.frequency, initialConfig.latest.weighted, { gasLimit })).wait();
    });

    it("Should handle very large frequency values", async function () {
      const initialConfig = await registry.leaderSelection();
      const maxUint64 = ethers.BigNumber.from("0xFFFFFFFFFFFFFFFF");

      // Set frequency to maximum uint64 value
      await (await registry.updateLeaderSelection(maxUint64, true, { gasLimit })).wait();

      const updatedConfig = await registry.leaderSelection();
      expect(updatedConfig.latest.frequency).to.equal(maxUint64);
      expect(updatedConfig.latest.weighted).to.equal(true);

      // Reset to original values
      await (await registry.updateLeaderSelection(initialConfig.latest.frequency, initialConfig.latest.weighted, { gasLimit })).wait();
    });

    it("Should handle leader selection configuration changes without commits", async function () {
      // Make multiple leader selection changes without committing
      await (await registry.updateLeaderSelection(5, true, { gasLimit })).wait();
      await (await registry.updateLeaderSelection(10, false, { gasLimit })).wait();
      await (await registry.updateLeaderSelection(15, true, { gasLimit })).wait();

      // Only the latest should be reflected
      const config = await registry.leaderSelection();
      expect(config.latest.frequency).to.equal(15);
      expect(config.latest.weighted).to.equal(true);

      // Snapshot should still be at defaults since no commit was made
      expect(config.snapshot.frequency).to.equal(1);
      expect(config.snapshot.weighted).to.equal(false);

      // Reset to original values
      await (await registry.updateLeaderSelection(1, false, { gasLimit })).wait();
    });
  });

  describe("Advanced Edge Cases and State Consistency", function () {
    it("Should maintain state consistency across complex operations", async function () {
      const entries = [];

      // Add multiple validators with different configurations
      for (let i = 0; i < 5; i++) {
        const entry = makeRandomValidatorEntry(makeRandomValidator(), 100 + i * 10);
        entry.validatorIsLeader = i < 3; // First 3 are leaders
        entry.validatorIsActive = i !== 2; // All except index 2 are active
        entries.push(entry);

        await (await registry.add(
          entry.ownerAddr,
          entry.validatorIsLeader,
          entry.validatorIsActive,
          entry.validatorWeight,
          entry.validatorPubKey,
          entry.validatorPoP
        )).wait();
      }

      // Verify initial active leader count (leaders 0,1 are active, leader 2 is inactive)
      expect(await registry.activeLeaderValidatorsCount()).to.equal(2);
      expect(await registry.numValidators()).to.equal(5);

      // Perform various operations
      await (await registry.changeValidatorActive(entries[2].ownerAddr, true)).wait(); // Activate inactive leader
      expect(await registry.activeLeaderValidatorsCount()).to.equal(3);

      await (await registry.changeValidatorLeader(entries[3].ownerAddr, true)).wait(); // Make non-leader a leader
      expect(await registry.activeLeaderValidatorsCount()).to.equal(4);

      await (await registry.remove(entries[0].ownerAddr)).wait(); // Remove a leader
      expect(await registry.activeLeaderValidatorsCount()).to.equal(3);

      // Commit and verify committee formation
      await (await registry.commitValidatorCommittee()).wait();
      const [committee] = await registry.getValidatorCommittee();
      expect(committee.length).to.equal(4); // 5 - 1 removed

      // Verify all arrays and mappings are consistent
      expect(await registry.numValidators()).to.equal(4); // After deletion during next operation
      expect(await registry.numRemovedValidators()).to.be.greaterThan(0);
    });

    it("Should handle operations on removed validators gracefully", async function () {
      const entry = makeRandomValidatorEntry(makeRandomValidator(), 100);
      await (await registry.add(
        entry.ownerAddr,
        true,
        true,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP
      )).wait();

      // Remove validator
      await (await registry.remove(entry.ownerAddr)).wait();

      // Operations on removed validator should be no-ops (not revert)
      await (await registry.changeValidatorActive(entry.ownerAddr, false)).wait();
      await (await registry.changeValidatorLeader(entry.ownerAddr, false)).wait();
      await (await registry.changeValidatorWeight(entry.ownerAddr, 200)).wait();

      const newKey = getRandomValidatorPubKey();
      const newPoP = getRandomValidatorPoP();
      await (await registry.changeValidatorKey(entry.ownerAddr, newKey, newPoP)).wait();

      // Double remove should also be a no-op
      await (await registry.remove(entry.ownerAddr)).wait();

      // Validator should still be marked as removed
      const validator = await registry.validators(entry.ownerAddr);
      expect(validator.latest.removed).to.equal(true);
    });

    it("Should handle initialization edge cases", async function () {
      // Test with zero address should fail during initialization
      const deployer = new Deployer(hre, owner);
      const registryInstance = await deployer.deploy(await deployer.loadArtifact("ConsensusRegistry"), []);

      const proxyInitializationParams = CONSENSUS_REGISTRY_INTERFACE.encodeFunctionData("initialize", [ethers.constants.AddressZero]);

      await expect(
        deployer.deploy(await deployer.loadArtifact("TransparentUpgradeableProxy"), [
          registryInstance.address,
          (await deployer.deploy(await deployer.loadArtifact("ProxyAdmin"), [])).address,
          proxyInitializationParams,
        ])
      ).to.be.reverted;
    });
  });
});
