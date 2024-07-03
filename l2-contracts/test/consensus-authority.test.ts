import {Deployer} from "@matterlabs/hardhat-zksync-deploy";
import * as hre from "hardhat";
import {Provider, Wallet} from "zksync-web3";
import {
    AttesterRegistry, AttesterRegistryFactory,
    ConsensusAuthority,
    ConsensusAuthorityFactory,
    ValidatorRegistry,
    ValidatorRegistryFactory
} from "../typechain";
import {expect} from "chai";
import {ethers} from "ethers";
import {loadTsNode} from "hardhat/internal/core/typescript-support";

const richAccount = {
    address: "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049",
    privateKey: "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110",
};

const gasLimit = 100_000_000;

describe("ConsensusAuthority", function () {
    const provider = new Provider(hre.config.networks.localhost.url);
    const owner = new Wallet(richAccount.privateKey, provider);
    const nonOwner = new Wallet(Wallet.createRandom().privateKey, provider);
    const nodes = [];
    const nodeEntries = [];
    let authority: ConsensusAuthority;
    let validatorRegistry: ValidatorRegistry;
    let attesterRegistry: AttesterRegistry;

    before("Initialize", async function () {
        // Deploy.
        const deployer = new Deployer(hre, owner);
        const authorityInstance = await deployer.deploy(await deployer.loadArtifact("ConsensusAuthority"), [owner.address]);
        authority = ConsensusAuthorityFactory.connect(authorityInstance.address, owner);
        validatorRegistry = ValidatorRegistryFactory.connect(await authority.validatorRegistry(), owner);
        attesterRegistry = AttesterRegistryFactory.connect(await authority.attesterRegistry(), owner);

        // Fund nonOwner.
        await (await owner.sendTransaction({
            to: nonOwner.address,
            value: ethers.utils.parseEther("100")
        })).wait();

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
            nodeEntries.push(nodeEntry)
        }

        // Fund the first node owner.
        await (await owner.sendTransaction({
            to: nodes[0].ownerKey.address,
            value: ethers.utils.parseEther("100")
        })).wait();
    });

    it("Should set the owner as provided in constructor, and set registries' owners as its own address", async function () {
        expect(await authority.owner()).to.equal(owner.address);
        expect(await validatorRegistry.owner()).to.equal(authority.address);
        expect(await attesterRegistry.owner()).to.equal(authority.address);
    });

    it("Should add nodes to both registries", async function () {
        for (let i = 0; i < nodes.length; i++) {
            await (await authority.add(
                nodeEntries[i].ownerAddr,
                nodeEntries[i].validatorWeight,
                nodeEntries[i].validatorPubKey,
                nodeEntries[i].validatorPoP,
                nodeEntries[i].attesterWeight,
                nodeEntries[i].attesterPubKey,
            )).wait();
        }

        expect(await validatorRegistry["numValidators()"]()).to.equal(nodes.length);
        expect(await attesterRegistry["numAttesters()"]()).to.equal(nodes.length);

        for (let i = 0; i < nodes.length; i++) {
            const validatorOwner = await validatorRegistry["validatorOwners(uint256)"](i);
            expect(validatorOwner).to.equal(nodeEntries[i].ownerAddr);
            const validator = await validatorRegistry.validators(validatorOwner);
            expect(validator.weight).to.equal(nodeEntries[i].validatorWeight);
            expect(validator.pubKey).to.equal(nodeEntries[i].validatorPubKey);
            expect(validator[2]).to.equal(nodeEntries[i].validatorPoP);
            expect(validator.isInactive).to.equal(false);

            const attesterOwner = await attesterRegistry["attesterOwners(uint256)"](i);
            expect(attesterOwner).to.equal(nodeEntries[i].ownerAddr);
            const attester = await validatorRegistry.validators(attesterOwner);
            expect(attester.weight).to.equal(nodeEntries[i].validatorWeight);
            expect(attester.pubKey).to.equal(nodeEntries[i].validatorPubKey);
            expect(attester.isInactive).to.equal(false);
        }
    });

    it("Should not allow nonOwner to add", async function () {
        await expect(authority.connect(nonOwner).add(
                ethers.Wallet.createRandom().address,
                0,
                "0x",
                "0x",
                0,
                "0x",
                {gasLimit}
            )
        ).to.be.reverted;
    });

    it("Should allow owner to inactivate", async function () {
        const nodeOwner = nodeEntries[0].ownerAddr;
        expect((await validatorRegistry.validators(nodeOwner)).isInactive).to.equal(false);

        await (await authority.connect(owner).inactivate(
            nodeOwner,
            {gasLimit}
        )).wait();
        expect((await validatorRegistry.validators(nodeOwner)).isInactive).to.equal(true);

        // Restore state.
        await (await authority.connect(owner).activate(
            nodeOwner,
            {gasLimit}
        )).wait();
    });

    it("Should allow the nodeOwner to inactivate", async function () {
        const nodeOwner = nodeEntries[0].ownerAddr;
        const nodeOwnerKey = nodes[0].ownerKey;
        expect((await validatorRegistry.validators(nodeOwner)).isInactive).to.equal(false);

        await (await authority.connect(nodeOwnerKey).inactivate(
            nodeOwner,
            {gasLimit}
        )).wait();
        expect((await validatorRegistry.validators(nodeOwner)).isInactive).to.equal(true);

        // Restore state.
        await (await authority.connect(owner).activate(
            nodeOwner,
            {gasLimit}
        )).wait();
    });

    it("Should not allow nonOwner, nonNodeOwner to inactivate", async function () {
        const nodeOwner = nodeEntries[0].ownerAddr;
        await expect(authority.connect(nonOwner).inactivate(
                nodeOwner,
                {gasLimit}
            )
        ).to.be.reverted;
    });

    it("Should change validator weight", async function () {
        const nodeEntry = nodeEntries[0];
        expect((await validatorRegistry.validators(nodeEntry.ownerAddr)).weight).to.equal(nodeEntry.validatorWeight);

        const baseWeight = nodeEntry.validatorWeight
        const newWeight = getRandomNumber(100, 1000);
        await (await authority.changeValidatorWeight(
            nodeEntry.ownerAddr,
            newWeight,
            {gasLimit}
        )).wait();
        expect((await validatorRegistry.validators(nodeEntry.ownerAddr)).weight).to.equal(newWeight);
        expect((await attesterRegistry.attesters(nodeEntry.ownerAddr)).weight).to.equal(nodeEntry.attesterWeight);

        // Restore state.
        await (await authority.changeValidatorWeight(
            nodeEntry.ownerAddr,
            baseWeight,
            {gasLimit}
        )).wait();
        expect((await validatorRegistry.validators(nodeEntry.ownerAddr)).weight).to.equal(baseWeight);
    });

    it("Should not allow nodeOwner to change validator weight", async function () {
        const node = nodes[0];
        await expect(authority.connect(node.ownerKey).changeValidatorWeight(
                node.ownerKey.address,
                0,
                {gasLimit}
            )
        ).to.be.reverted;
    });

    it("Should not allow nonOwner to change validator weight", async function () {
        const node = nodes[0];
        await expect(authority.connect(nonOwner).changeValidatorWeight(
                node.ownerKey.address,
                0,
                {gasLimit}
            )
        ).to.be.reverted;
    });

    it("Should change attester weight", async function () {
        const nodeEntry = nodeEntries[0];
        expect((await attesterRegistry.attesters(nodeEntry.ownerAddr)).weight).to.equal(nodeEntry.attesterWeight);

        const baseWeight = nodeEntry.attesterWeight
        const newWeight = getRandomNumber(100, 1000);
        await (await authority.changeAttesterWeight(
            nodeEntry.ownerAddr,
            newWeight,
            {gasLimit}
        )).wait();
        expect((await attesterRegistry.attesters(nodeEntry.ownerAddr)).weight).to.equal(newWeight);
        expect((await validatorRegistry.validators(nodeEntry.ownerAddr)).weight).to.equal(nodeEntry.validatorWeight);

        // Restore state.
        await (await authority.changeAttesterWeight(
            nodeEntry.ownerAddr,
            baseWeight,
            {gasLimit}
        )).wait();
        expect((await attesterRegistry.attesters(nodeEntry.ownerAddr)).weight).to.equal(baseWeight);
    });

    it("Should not allow nodeOwner to change attester weight", async function () {
        const node = nodes[0];
        await expect(authority.connect(node.ownerKey).changeAttesterWeight(
                node.ownerKey.address,
                0,
                {gasLimit}
            )
        ).to.be.reverted;
    });

    it("Should not allow nonOwner to change attester weight", async function () {
        const node = nodes[0];
        await expect(authority.connect(nonOwner).changeAttesterWeight(
                node.ownerKey.address,
                0,
                {gasLimit}
            )
        ).to.be.reverted;
    });

});

function getRandomNumber(min, max) {
    return Math.floor(Math.random() * (max - min + 1)) + min;
}