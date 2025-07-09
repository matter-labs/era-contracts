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
  const nodes = [];
  const nodeEntries = [];
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

    // Prepare the node list.
    const numNodes = 10;
    for (let i = 0; i < numNodes; i++) {
      const node = makeRandomNode();
      const nodeEntry = makeRandomNodeEntry(node, i + 1);
      nodes.push(node);
      nodeEntries.push(nodeEntry);
    }

    // Fund the first node owner.
    await (
      await owner.sendTransaction({
        to: nodes[0].ownerKey.address,
        value: ethers.utils.parseEther("100"),
      })
    ).wait();
  });

  it("Should set the owner as provided in constructor", async function () {
    expect(await registry.owner()).to.equal(owner.address);
  });

  it("Should add nodes to both registries", async function () {
    for (let i = 0; i < nodes.length; i++) {
      await (
        await registry.add(
          nodeEntries[i].ownerAddr,
          true,
          nodeEntries[i].validatorWeight,
          nodeEntries[i].validatorPubKey,
          nodeEntries[i].validatorPoP,
          true,
          nodeEntries[i].attesterWeight,
          nodeEntries[i].attesterPubKey,
          { gasLimit }
        )
      ).wait();
    }

    expect(await registry.numNodes()).to.equal(nodes.length);

    for (let i = 0; i < nodes.length; i++) {
      const nodeOwner = await registry.nodeOwners(i);
      expect(nodeOwner).to.equal(nodeEntries[i].ownerAddr);
      const node = await registry.nodes(nodeOwner);
      expect(node.attesterLastUpdateCommit).to.equal(0);
      expect(node.validatorLastUpdateCommit).to.equal(0);

      // 'Latest' is expected to match the added node's attributes.
      expect(node.attesterLatest.active).to.equal(true);
      expect(node.attesterLatest.removed).to.equal(false);
      expect(node.attesterLatest.weight).to.equal(nodeEntries[i].attesterWeight);
      expect(node.attesterLatest.pubKey.tag).to.equal(nodeEntries[i].attesterPubKey.tag);
      expect(node.attesterLatest.pubKey.x).to.equal(nodeEntries[i].attesterPubKey.x);
      expect(node.validatorLastUpdateCommit).to.equal(0);
      expect(node.validatorLatest.active).to.equal(true);
      expect(node.validatorLatest.removed).to.equal(false);
      expect(node.validatorLatest.weight).to.equal(nodeEntries[i].attesterWeight);
      expect(node.validatorLatest.pubKey.a).to.equal(nodeEntries[i].validatorPubKey.a);
      expect(node.validatorLatest.pubKey.b).to.equal(nodeEntries[i].validatorPubKey.b);
      expect(node.validatorLatest.pubKey.c).to.equal(nodeEntries[i].validatorPubKey.c);
      expect(node.validatorLatest.proofOfPossession.a).to.equal(nodeEntries[i].validatorPoP.a);
      expect(node.validatorLatest.proofOfPossession.b).to.equal(nodeEntries[i].validatorPoP.b);

      // 'Snapshot' is expected to have zero values.
      expect(node.attesterSnapshot.active).to.equal(false);
      expect(node.attesterSnapshot.removed).to.equal(false);
      expect(node.attesterSnapshot.weight).to.equal(0);
      expect(ethers.utils.arrayify(node.attesterSnapshot.pubKey.tag)).to.deep.equal(new Uint8Array(1));
      expect(ethers.utils.arrayify(node.attesterSnapshot.pubKey.x)).to.deep.equal(new Uint8Array(32));
      expect(node.validatorSnapshot.active).to.equal(false);
      expect(node.validatorSnapshot.removed).to.equal(false);
      expect(node.validatorSnapshot.weight).to.equal(0);
      expect(ethers.utils.arrayify(node.validatorSnapshot.pubKey.a)).to.deep.equal(new Uint8Array(32));
      expect(ethers.utils.arrayify(node.validatorSnapshot.pubKey.b)).to.deep.equal(new Uint8Array(32));
      expect(ethers.utils.arrayify(node.validatorSnapshot.pubKey.c)).to.deep.equal(new Uint8Array(32));
      expect(ethers.utils.arrayify(node.validatorSnapshot.proofOfPossession.a)).to.deep.equal(new Uint8Array(32));
      expect(ethers.utils.arrayify(node.validatorSnapshot.proofOfPossession.b)).to.deep.equal(new Uint8Array(16));
    }
  });

  it("Should not allow validatorOwner to add", async function () {
    await expect(
      registry
        .connect(validators[0].ownerKey)
        .add(
          ethers.Wallet.createRandom().address,
          true,
          0,
          { a: new Uint8Array(32), b: new Uint8Array(32), c: new Uint8Array(32) },
          { a: new Uint8Array(32), b: new Uint8Array(16) },
          true,
          0,
          { tag: new Uint8Array(1), x: new Uint8Array(32) },
          { gasLimit }
        )
    ).to.be.reverted;
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

  it("Should not allow to add a validator with an owner address which already exists", async function () {
    const newEntry = makeRandomValidatorEntry(makeRandomValidator(), 0);
    await expect(
      registry.add(
        validatorEntries[0].ownerAddr, // Using an existing owner address
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

  it("Should not allow nonOwner to change validator active status", async function () {
    const validatorOwner = validatorEntries[0].ownerAddr;
    await expect(registry.connect(nonOwner).changeValidatorActive(validatorOwner, false, { gasLimit })).to.be.reverted;
  });

  it("Should change validator weight", async function () {
    const entry = nodeEntries[0];
    expect((await registry.nodes(entry.ownerAddr)).validatorLatest.weight).to.equal(entry.validatorWeight);

    const baseWeight = entry.validatorWeight;
    const newWeight = getRandomNumber(100, 1000);
    await (await registry.changeValidatorWeight(entry.ownerAddr, newWeight, { gasLimit })).wait();
    expect((await registry.nodes(entry.ownerAddr)).validatorLatest.weight).to.equal(newWeight);
    expect((await registry.nodes(entry.ownerAddr)).attesterLatest.weight).to.equal(entry.attesterWeight);

    // Restore state.
    await (await registry.changeValidatorWeight(entry.ownerAddr, baseWeight, { gasLimit })).wait();
  });

  it("Should not allow validatorOwner to change validator weight", async function () {
    const validator = validators[0];
    await expect(
      registry.connect(validator.ownerKey).changeValidatorWeight(validator.ownerKey.address, 0, { gasLimit })
    ).to.be.reverted;
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

  it("Should not allow validatorOwner to change validator leader status", async function () {
    const validator = validators[0];
    await expect(
      registry.connect(validator.ownerKey).changeValidatorLeader(validator.ownerKey.address, true, { gasLimit })
    ).to.be.reverted;
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

  it("Should not allow nonOwner to change validator public key", async function () {
    const validator = makeRandomValidatorEntry(makeRandomValidator(), 0);
    await expect(
      registry
        .connect(nonOwner)
        .changeValidatorKey(validator.ownerAddr, validator.validatorPubKey, validator.validatorPoP, { gasLimit })
    ).to.be.reverted;
  });

  it("Should not allow to add a node with an attester public key which already exist", async function () {
    const newEntry = makeRandomNodeEntry(makeRandomNode(), 1);
    await expect(
      registry.add(
        newEntry.ownerAddr,
        true,
        newEntry.validatorWeight,
        newEntry.validatorPubKey,
        newEntry.validatorPoP,
        true,
        newEntry.attesterWeight,
        nodeEntries[0].attesterPubKey,
        { gasLimit }
      )
    ).to.be.reverted;
  });

  it("Should return attester committee once committed to", async function () {
    // Verify that committee was not committed to.
    expect((await registry.getAttesterCommittee()).length).to.equal(0);

    // Commit.
    await (await registry.commitAttesterCommittee({ gasLimit })).wait();

    // Read committee.
    const attesterCommittee = await registry.getAttesterCommittee();
    expect(attesterCommittee.length).to.equal(nodes.length);
    for (let i = 0; i < attesterCommittee.length; i++) {
      const entry = nodeEntries[i];
      const attester = attesterCommittee[i];
      expect(attester.weight).to.equal(entry.attesterWeight);
      expect(attester.pubKey.tag).to.equal(entry.attesterPubKey.tag);
      expect(attester.pubKey.x).to.equal(entry.attesterPubKey.x);
    }
  });

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
      const entry = nodeEntries[i];
      const validator = validatorCommittee[i];
      expect(validator.weight).to.equal(entry.validatorWeight);
      expect(validator.pubKey.a).to.equal(entry.validatorPubKey.a);
      expect(validator.pubKey.b).to.equal(entry.validatorPubKey.b);
      expect(validator.pubKey.c).to.equal(entry.validatorPubKey.c);
      expect(validator.proofOfPossession.a).to.equal(entry.validatorPoP.a);
      expect(validator.proofOfPossession.b).to.equal(entry.validatorPoP.b);
    }
  });

  it("Should not include inactive nodes in attester and validator committees when committed to", async function () {
    const idx = nodeEntries.length - 1;
    const entry = nodeEntries[idx];

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

  it("Should not include removed nodes in attester and validator committees when committed to", async function () {
    const idx = nodeEntries.length - 1;
    const entry = nodeEntries[idx];

    // Remove node.
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
        true,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP,
        true,
        entry.attesterWeight,
        entry.attesterPubKey
      )
    ).wait();
    await (await registry.commitAttesterCommittee({ gasLimit })).wait();
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

  it("Should not include validator attribute change in committee before committed to", async function () {
    const idx = validatorEntries.length - 1;
    const entry = validatorEntries[idx];

    // Change attribute.
    await (await registry.changeAttesterWeight(entry.ownerAddr, entry.attesterWeight + 1, { gasLimit })).wait();

    // Verify no change.
    const attester = (await registry.getAttesterCommittee())[idx];
    expect(attester.weight).to.equal(entry.attesterWeight);

    // Commit.
    await (await registry.commitAttesterCommittee({ gasLimit })).wait();

    // Verify change.
    const committedAttester = (await registry.getAttesterCommittee())[idx];
    expect(committedAttester.weight).to.equal(entry.attesterWeight + 1);

    // Restore state.
    await (await registry.changeAttesterWeight(entry.ownerAddr, entry.attesterWeight, { gasLimit })).wait();
    await (await registry.commitAttesterCommittee({ gasLimit })).wait();
  });

  it("Should not include node attribute change in validator committee before committed to", async function () {
    const idx = nodeEntries.length - 1;
    const entry = nodeEntries[idx];

    // Change attribute.
    await (await registry.changeValidatorWeight(entry.ownerAddr, entry.attesterWeight + 1, { gasLimit })).wait();

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

  it("Should finalize node removal by fully deleting it from storage", async function () {
    const idx = nodeEntries.length - 1;
    const entry = nodeEntries[idx];

    // Remove.
    expect((await registry.nodes(entry.ownerAddr)).attesterLatest.removed).to.equal(false);
    expect((await registry.nodes(entry.ownerAddr)).validatorLatest.removed).to.equal(false);
    await (await registry.remove(entry.ownerAddr, { gasLimit })).wait();
    expect((await registry.nodes(entry.ownerAddr)).attesterLatest.removed).to.equal(true);
    expect((await registry.nodes(entry.ownerAddr)).validatorLatest.removed).to.equal(true);

    // Commit committees.
    await (await registry.commitAttesterCommittee({ gasLimit })).wait();
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();

    // Verify node was not yet deleted.
    expect(await registry.numNodes()).to.equal(nodes.length);
    const attesterPubKeyHash = hashAttesterPubKey(entry.attesterPubKey);
    expect(await registry.attesterPubKeyHashes(attesterPubKeyHash)).to.be.equal(true);
    const validatorPubKeyHash = hashValidatorPubKey(entry.validatorPubKey);
    expect(await registry.validatorPubKeyHashes(validatorPubKeyHash)).to.be.equal(true);

    // Trigger node deletion.
    await (await registry.remove(entry.ownerAddr, { gasLimit })).wait();

    // Verify the deletion.
    expect(await registry.numNodes()).to.equal(nodes.length - 1);
    expect(await registry.attesterPubKeyHashes(attesterPubKeyHash)).to.be.equal(false);
    expect(await registry.validatorPubKeyHashes(attesterPubKeyHash)).to.be.equal(false);
    const node = await registry.nodes(entry.ownerAddr, { gasLimit });
    expect(ethers.utils.arrayify(node.attesterLatest.pubKey.tag)).to.deep.equal(new Uint8Array(1));
    expect(ethers.utils.arrayify(node.attesterLatest.pubKey.x)).to.deep.equal(new Uint8Array(32));

    // Restore state.
    await (
      await registry.add(
        entry.ownerAddr,
        true,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP,
        true,
        entry.attesterWeight,
        entry.attesterPubKey
      )
    ).wait();
    await (await registry.commitAttesterCommittee({ gasLimit })).wait();
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();
  });

  it("Should have default leader selection configuration after initialization", async function () {
    const leaderSelection = await registry.leaderSelection();
    expect(leaderSelection.latest.frequency).to.equal(1);
    expect(leaderSelection.latest.weighted).to.equal(false);
  });

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

  it("Should not allow validatorOwner to update leader selection", async function () {
    await expect(registry.connect(validators[0].ownerKey).updateLeaderSelection(5, true, { gasLimit })).to.be.reverted;
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

  function makeRandomValidator(provider?) {
    return {
      ownerKey: new Wallet(Wallet.createRandom().privateKey, provider),
      validatorKey: Wallet.createRandom(),
      attesterKey: Wallet.createRandom(),
    };
  }

  function makeRandomNodeEntry(node, weight: number) {
    return {
      ownerAddr: node.ownerKey.address,
      validatorWeight: weight,
      validatorPubKey: getRandomValidatorPubKey(),
      validatorPoP: getRandomValidatorPoP(),
      attesterWeight: weight,
      attesterPubKey: getRandomAttesterPubKey(),
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

function getRandomAttesterPubKey() {
  return {
    tag: ethers.utils.hexlify(ethers.utils.randomBytes(1)),
    x: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
  };
}

function hashAttesterPubKey(attesterPubKey) {
  return ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(["bytes1", "bytes32"], [attesterPubKey.tag, attesterPubKey.x])
  );
}

function hashValidatorPubKey(validatorPubKey) {
  return ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["bytes32", "bytes32", "bytes32"],
      [validatorPubKey.a, validatorPubKey.b, validatorPubKey.c]
    )
  );
}
