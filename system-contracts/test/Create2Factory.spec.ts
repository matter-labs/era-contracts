import { expect } from "chai";
import { ethers } from "hardhat";
import type { Wallet } from "zksync-ethers";
import type { Create2Factory } from "../typechain";
import { deployContract, getWallets, loadArtifact } from "./shared/utils";
import { create2Address, getDeployedContracts, hashBytecode } from "zksync-ethers/build/utils";

describe("Create2Factory tests", function () {
  let wallet: Wallet;
  let contractFactory: Create2Factory;

  before(async () => {
    wallet = getWallets()[0];
    contractFactory = (await deployContract("Create2Factory", [])) as Create2Factory;
  });

  it("Should deploy contract with create2", async () => {
    // For simplicity, we'll just deploy a contract factory
    const salt = ethers.utils.randomBytes(32);
    const bytecode = await (await loadArtifact("Create2Factory")).bytecode;
    const hash = hashBytecode(bytecode);

    const deploymentTx = await (await contractFactory.create2(salt, hash, [])).wait();

    const deployedAddresses = getDeployedContracts(deploymentTx);
    expect(deployedAddresses.length).to.equal(1);
    const deployedAddress = deployedAddresses[0];
    const correctCreate2Address = create2Address(contractFactory.address, hash, salt, []);

    expect(deployedAddress.deployedAddress.toLocaleLowerCase()).to.equal(correctCreate2Address.toLocaleLowerCase());
    expect(await wallet.provider.getCode(deployedAddress.deployedAddress)).to.equal(bytecode);
  });
});
