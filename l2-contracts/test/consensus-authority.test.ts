import { Deployer } from "@matterlabs/hardhat-zksync-deploy";
import * as hre from "hardhat";
import { Provider, Wallet } from "zksync-web3";
import {ConsensusAuthority, ConsensusAuthorityFactory} from "../typechain";

const richAccount = {
  address: "0x36615Cf349d7F6344891B1e7CA7C72883F5dc049",
  privateKey: "0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110",
};

describe("ConsensusAuthority", function () {
  const provider = new Provider(hre.config.networks.localhost.url);
  const wallet = new Wallet(richAccount.privateKey, provider);
  let authority: ConsensusAuthority;

  before("Deploy", async function () {
    const deployer = new Deployer(hre, wallet);
    const owner = wallet.address;
    const authorityImpl = await deployer.deploy(await deployer.loadArtifact("ConsensusAuthority"), [owner]);
    authority = ConsensusAuthorityFactory.connect(authorityImpl.address, wallet);
    console.log(`owner: ${owner}`);
  });

  it("Sanity", async function () {
    console.log(`owner: ${await authority.owner()}`);
    console.log(`validatorRegistry: ${await authority.validatorRegistry()}`);
    console.log(`attesterRegistry: ${await authority.attesterRegistry()}`);
  });
});
