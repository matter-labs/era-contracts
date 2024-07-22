import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import * as hre from "hardhat";
import { Provider, Wallet } from "zksync-web3";
import type { ConsensusRegistry } from "../typechain";
import { ConsensusRegistryFactory } from "../typechain";
import { expect } from "chai";
import { ethers } from "ethers";

const richAccount = {
  address: "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049",
  privateKey: "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110",
};

const gasLimit = 100_000_000;

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
    const registryInstance = await deployer.deploy(await deployer.loadArtifact("ConsensusRegistry"), [owner.address]);
    registry = ConsensusRegistryFactory.connect(registryInstance.address, owner);

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
      const node = {
        ownerKey: new Wallet(Wallet.createRandom().privateKey, provider),
        validatorKey: Wallet.createRandom(),
        attesterKey: Wallet.createRandom(),
      };

      const nodeEntry = {
        ownerAddr: node.ownerKey.address,
        validatorWeight: i,
        validatorPubKey: ethers.utils.computePublicKey(node.validatorKey.privateKey),
        validatorPoP: await node.validatorKey.signMessage(ethers.utils.computePublicKey(node.validatorKey.privateKey)),
        attesterWeight: i,
        attesterPubKey: ethers.utils.computePublicKey(node.validatorKey.privateKey),
      };

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

    expect(await registry["numNodes()"]()).to.equal(nodes.length);

    for (let i = 0; i < nodes.length; i++) {
      const nodeOwner = await registry["nodeOwners(uint256)"](i);
      expect(nodeOwner).to.equal(nodeEntries[i].ownerAddr);

      const node = await registry.nodes(nodeOwner);
      expect(node.isInactive).to.equal(false);
      expect(node.validatorWeight).to.equal(nodeEntries[i].validatorWeight);
      expect(node.validatorPubKey).to.equal(nodeEntries[i].validatorPubKey);
      expect(node.validatorPoP).to.equal(nodeEntries[i].validatorPoP);
      expect(node.attesterWeight).to.equal(nodeEntries[i].attesterWeight);
      expect(node.attesterPubKey).to.equal(nodeEntries[i].attesterPubKey);
    }
  });

  it("Should not allow nonOwner to add", async function () {
    await expect(
      registry.connect(nonOwner).add(ethers.Wallet.createRandom().address, 0, "0x", "0x", 0, "0x", { gasLimit })
    ).to.be.reverted;
  });

  it("Should allow owner to deactivate", async function () {
    const nodeOwner = nodeEntries[0].ownerAddr;
    expect((await registry.nodes(nodeOwner)).isInactive).to.equal(false);

    await (await registry.connect(owner).deactivate(nodeOwner, { gasLimit })).wait();
    expect((await registry.nodes(nodeOwner)).isInactive).to.equal(true);

    // Restore state.
    await (await registry.connect(owner).activate(nodeOwner, { gasLimit })).wait();
  });

  it("Should allow the nodeOwner to deactivate", async function () {
    const nodeOwner = nodeEntries[0].ownerAddr;
    const nodeOwnerKey = nodes[0].ownerKey;
    expect((await registry.nodes(nodeOwner)).isInactive).to.equal(false);

    await (await registry.connect(nodeOwnerKey).deactivate(nodeOwner, { gasLimit })).wait();
    expect((await registry.nodes(nodeOwner)).isInactive).to.equal(true);

    // Restore state.
    await (await registry.connect(owner).activate(nodeOwner, { gasLimit })).wait();
  });

  it("Should not allow nonOwner, nonNodeOwner to deactivate", async function () {
    const nodeOwner = nodeEntries[0].ownerAddr;
    await expect(registry.connect(nonOwner).deactivate(nodeOwner, { gasLimit })).to.be.reverted;
  });

  it("Should change validator weight", async function () {
    const nodeEntry = nodeEntries[0];
    expect((await registry.nodes(nodeEntry.ownerAddr)).validatorWeight).to.equal(nodeEntry.validatorWeight);

    const baseWeight = nodeEntry.validatorWeight;
    const newWeight = getRandomNumber(100, 1000);
    await (await registry.changeValidatorWeight(nodeEntry.ownerAddr, newWeight, { gasLimit })).wait();
    expect((await registry.nodes(nodeEntry.ownerAddr)).validatorWeight).to.equal(newWeight);
    expect((await registry.nodes(nodeEntry.ownerAddr)).attesterWeight).to.equal(nodeEntry.attesterWeight);

    // Restore state.
    await (await registry.changeValidatorWeight(nodeEntry.ownerAddr, baseWeight, { gasLimit })).wait();
    expect((await registry.nodes(nodeEntry.ownerAddr)).validatorWeight).to.equal(baseWeight);
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
    const nodeEntry = nodeEntries[0];
    expect((await registry.nodes(nodeEntry.ownerAddr)).attesterWeight).to.equal(nodeEntry.attesterWeight);

    const baseWeight = nodeEntry.attesterWeight;
    const newWeight = getRandomNumber(100, 1000);
    await (await registry.changeAttesterWeight(nodeEntry.ownerAddr, newWeight, { gasLimit })).wait();
    expect((await registry.nodes(nodeEntry.ownerAddr)).attesterWeight).to.equal(newWeight);
    expect((await registry.nodes(nodeEntry.ownerAddr)).validatorWeight).to.equal(nodeEntry.validatorWeight);

    // Restore state.
    await (await registry.changeAttesterWeight(nodeEntry.ownerAddr, baseWeight, { gasLimit })).wait();
    expect((await registry.nodes(nodeEntry.ownerAddr)).attesterWeight).to.equal(baseWeight);
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
});

function getRandomNumber(min, max) {
  return Math.floor(Math.random() * (max - min + 1)) + min;
}
