import { expect } from "chai";
import { ethers } from "hardhat";
import type { Wallet } from "zksync-ethers";
import type { EmptyContract } from "../typechain";
import { deployContract, getWallets, provider } from "./shared/utils";

describe("EmptyContract tests", function () {
  let wallet: Wallet;
  let emptyContract: EmptyContract;

  before(async () => {
    wallet = getWallets()[0];
    emptyContract = (await deployContract("EmptyContract")) as EmptyContract;
  });

  it("zero value", async () => {
    const tx = {
      from: wallet.address,
      to: emptyContract.address,
      value: 0,
      data: "0x1234567890deadbeef1234567890",
    };
    expect(await provider.call(tx)).to.be.eq("0x");
  });

  it("non-zero value", async () => {
    const tx = {
      from: wallet.address,
      to: emptyContract.address,
      value: ethers.utils.parseEther("1.0"),
      data: "0x1234567890deadbeef1234567890",
    };
    expect(await provider.call(tx)).to.be.eq("0x");
  });

  it("empty calldata", async () => {
    const tx = {
      from: wallet.address,
      to: emptyContract.address,
      data: "",
    };
    expect(await provider.call(tx)).to.be.eq("0x");
  });
});
