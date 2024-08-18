import {Deployer} from "@matterlabs/hardhat-zksync-deploy";
import * as hre from "hardhat";
import {Provider, Wallet} from "zksync-web3";
import type {ConsensusRegistry} from "../typechain";
import {ConsensusRegistryFactory} from "../typechain";
import {expect} from "chai";
import {ethers} from "ethers";

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
                validatorPubKey: deriveValidatorPubKey(node.validatorKey),
                validatorPoP: deriveValidatorPoP(node.validatorKey),
                attesterWeight: i,
                attesterPubKey: deriveAttesterPubKey(node.attesterKey)
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
            registry.connect(nonOwner).add(ethers.Wallet.createRandom().address,
                0,
                {a: new Uint8Array(32), b: new Uint8Array(32), c: new Uint8Array(32)},
                {a: new Uint8Array(32), b: new Uint8Array(16)},
                0,
                {tag: new Uint8Array(1), x: new Uint8Array(32)},
                {gasLimit}
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
      const nodeEntry = nodeEntries[0];
      expect((await registry.nodes(nodeEntry.ownerAddr)).validatorLatest.weight).to.equal(nodeEntry.validatorWeight);

      const baseWeight = nodeEntry.validatorWeight;
      const newWeight = getRandomNumber(100, 1000);
      await (await registry.changeValidatorWeight(nodeEntry.ownerAddr, newWeight, { gasLimit })).wait();
      expect((await registry.nodes(nodeEntry.ownerAddr)).validatorLatest.weight).to.equal(newWeight);
      expect((await registry.nodes(nodeEntry.ownerAddr)).attesterLatest.weight).to.equal(nodeEntry.attesterWeight);

      // Restore state.
      await (await registry.changeValidatorWeight(nodeEntry.ownerAddr, baseWeight, { gasLimit })).wait();
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
      expect((await registry.nodes(nodeEntry.ownerAddr)).attesterLatest.weight).to.equal(nodeEntry.attesterWeight);

      const baseWeight = nodeEntry.attesterWeight;
      const newWeight = getRandomNumber(100, 1000);
      await (await registry.changeAttesterWeight(nodeEntry.ownerAddr, newWeight, { gasLimit })).wait();
      expect((await registry.nodes(nodeEntry.ownerAddr)).attesterLatest.weight).to.equal(newWeight);
      expect((await registry.nodes(nodeEntry.ownerAddr)).validatorLatest.weight).to.equal(nodeEntry.validatorWeight);

      // Restore state.
      await (await registry.changeAttesterWeight(nodeEntry.ownerAddr, baseWeight, { gasLimit })).wait();
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

function deriveValidatorPubKey(wallet: Wallet) {
    // TODO: implement 'ethers.utils.computePublicKey(wallet.privateKey)'
    return {
        a: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
        b: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
        c: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
    }
}

function deriveValidatorPoP(wallet: Wallet) {
    // TODO: implement 'await wallet.signMessage(ethers.utils.computePublicKey(wallet.privateKey))'
    return {
        a: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
        b: ethers.utils.hexlify(ethers.utils.randomBytes(16)),
    }
}

function deriveAttesterPubKey(wallet: Wallet) {
    // TODO: implement 'ethers.utils.computePublicKey(wallet.privateKey)'
    return {
        tag: ethers.utils.hexlify(ethers.utils.randomBytes(1)),
        x: ethers.utils.hexlify(ethers.utils.randomBytes(32)),
    }
}
