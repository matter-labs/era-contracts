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
      const node = makeRandomNode(provider);
      const nodeEntry = makeRandomNodeEntry(node, i);
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
          nodeEntries[i].validatorWeight,
          nodeEntries[i].validatorPubKey,
          nodeEntries[i].validatorPoP,
          nodeEntries[i].attesterWeight,
          nodeEntries[i].attesterPubKey
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

  it("Should not allow nonOwner to add", async function () {
    await expect(
      registry
        .connect(nonOwner)
        .add(
          ethers.Wallet.createRandom().address,
          0,
          { a: new Uint8Array(32), b: new Uint8Array(32), c: new Uint8Array(32) },
          { a: new Uint8Array(32), b: new Uint8Array(16) },
          0,
          { tag: new Uint8Array(1), x: new Uint8Array(32) },
          { gasLimit }
        )
    ).to.be.reverted;
  });

  it("Should allow owner to deactivate", async function () {
    const nodeOwner = nodeEntries[0].ownerAddr;
    expect((await registry.nodes(nodeOwner)).validatorLatest.active).to.equal(true);

    await (await registry.connect(owner).deactivate(nodeOwner, { gasLimit })).wait();
    expect((await registry.nodes(nodeOwner)).validatorLatest.active).to.equal(false);

    // Restore state.
    await (await registry.connect(owner).activate(nodeOwner, { gasLimit })).wait();
  });

  it("Should not allow nonOwner, nonNodeOwner to deactivate", async function () {
    const nodeOwner = nodeEntries[0].ownerAddr;
    await expect(registry.connect(nonOwner).deactivate(nodeOwner, { gasLimit })).to.be.reverted;
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

  it("Should not allow nodeOwner to change validator weight", async function () {
    const node = nodes[0];
    await expect(registry.connect(node.ownerKey).changeValidatorWeight(node.ownerKey.address, 0, { gasLimit })).to.be
      .reverted;
  });

  it("Should not allow nonOwner to change validator weight", async function () {
    const node = nodes[0];
    await expect(registry.connect(nonOwner).changeValidatorWeight(node.ownerKey.address, 0, { gasLimit })).to.be
      .reverted;
  });

  it("Should change attester weight", async function () {
    const entry = nodeEntries[0];
    expect((await registry.nodes(entry.ownerAddr)).attesterLatest.weight).to.equal(entry.attesterWeight);

    const baseWeight = entry.attesterWeight;
    const newWeight = getRandomNumber(100, 1000);
    await (await registry.changeAttesterWeight(entry.ownerAddr, newWeight, { gasLimit })).wait();
    expect((await registry.nodes(entry.ownerAddr)).attesterLatest.weight).to.equal(newWeight);
    expect((await registry.nodes(entry.ownerAddr)).validatorLatest.weight).to.equal(entry.validatorWeight);

    // Restore state.
    await (await registry.changeAttesterWeight(entry.ownerAddr, baseWeight, { gasLimit })).wait();
  });

  it("Should not allow nodeOwner to change attester weight", async function () {
    const node = nodes[0];
    await expect(registry.connect(node.ownerKey).changeAttesterWeight(node.ownerKey.address, 0, { gasLimit })).to.be
      .reverted;
  });

  it("Should not allow nonOwner to change attester weight", async function () {
    const node = nodes[0];
    await expect(registry.connect(nonOwner).changeAttesterWeight(node.ownerKey.address, 0, { gasLimit })).to.be
      .reverted;
  });

  it("Should not allow to add a node with a validator public key which already exist", async function () {
    const newEntry = makeRandomNodeEntry(makeRandomNode(), 0);
    await expect(
      registry.add(
        newEntry.ownerAddr,
        newEntry.validatorWeight,
        nodeEntries[0].validatorPubKey,
        newEntry.validatorPoP,
        newEntry.attesterWeight,
        newEntry.attesterPubKey,
        { gasLimit }
      )
    ).to.be.reverted;
  });

  it("Should not allow to add a node with an attester public key which already exist", async function () {
    const newEntry = makeRandomNodeEntry(makeRandomNode(), 0);
    await expect(
      registry.add(
        newEntry.ownerAddr,
        newEntry.validatorWeight,
        newEntry.validatorPubKey,
        newEntry.validatorPoP,
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
    expect((await registry.getValidatorCommittee()).length).to.equal(0);

    // Commit.
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();

    // Read committee.
    const validatorCommittee = await registry.getValidatorCommittee();
    expect(validatorCommittee.length).to.equal(nodes.length);
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

    // Deactivate attribute.
    await (await registry.deactivate(entry.ownerAddr, { gasLimit })).wait();

    // Verify no change.
    expect((await registry.getAttesterCommittee()).length).to.equal(nodes.length);
    expect((await registry.getValidatorCommittee()).length).to.equal(nodes.length);

    // Commit attester committee and verify.
    await (await registry.commitAttesterCommittee({ gasLimit })).wait();
    expect((await registry.getAttesterCommittee()).length).to.equal(nodes.length - 1);
    expect((await registry.getValidatorCommittee()).length).to.equal(nodes.length);

    // Commit validator committee and verify.
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();
    expect((await registry.getAttesterCommittee()).length).to.equal(nodes.length - 1);
    expect((await registry.getValidatorCommittee()).length).to.equal(nodes.length - 1);

    // Restore state.
    await (await registry.activate(entry.ownerAddr, { gasLimit })).wait();
    await (await registry.commitAttesterCommittee({ gasLimit })).wait();
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();
  });

  it("Should not include removed nodes in attester and validator committees when committed to", async function () {
    const idx = nodeEntries.length - 1;
    const entry = nodeEntries[idx];

    // Remove node.
    await (await registry.remove(entry.ownerAddr, { gasLimit })).wait();

    // Verify no change.
    expect((await registry.getAttesterCommittee()).length).to.equal(nodes.length);
    expect((await registry.getValidatorCommittee()).length).to.equal(nodes.length);

    // Commit attester committee and verify.
    await (await registry.commitAttesterCommittee({ gasLimit })).wait();
    expect((await registry.getAttesterCommittee()).length).to.equal(nodes.length - 1);
    expect((await registry.getValidatorCommittee()).length).to.equal(nodes.length);

    // Commit validator committee and verify.
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();
    expect((await registry.getAttesterCommittee()).length).to.equal(nodes.length - 1);
    expect((await registry.getValidatorCommittee()).length).to.equal(nodes.length - 1);

    // Restore state.
    await (await registry.remove(entry.ownerAddr, { gasLimit })).wait();
    await (
      await registry.add(
        entry.ownerAddr,
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP,
        entry.attesterWeight,
        entry.attesterPubKey
      )
    ).wait();
    await (await registry.commitAttesterCommittee({ gasLimit })).wait();
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();
  });

  it("Should not include node attribute change in attester committee before committed to", async function () {
    const idx = nodeEntries.length - 1;
    const entry = nodeEntries[idx];

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
        entry.validatorWeight,
        entry.validatorPubKey,
        entry.validatorPoP,
        entry.attesterWeight,
        entry.attesterPubKey
      )
    ).wait();
    await (await registry.commitAttesterCommittee({ gasLimit })).wait();
    await (await registry.commitValidatorCommittee({ gasLimit })).wait();
  });

  function makeRandomNode() {
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
