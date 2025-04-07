import { ethers } from "hardhat";
import { enableEvmEmulation } from "./shared/utils";
import { ContractFactory } from "ethers";
import { expect } from "chai";

describe("EvmEmulation tests", function () {
  it("Can enable evm emulation", async () => {
    await enableEvmEmulation();
  });

  const testAbi = [
    "constructor(uint256 initialValue)",
    "function value() view returns (uint)"
  ];

  const testEvmBytecode = "0x6080604052348015600e575f80fd5b506040516101493803806101498339818101604052810190602e9190606b565b805f81905550506091565b5f80fd5b5f819050919050565b604d81603d565b81146056575f80fd5b50565b5f815190506065816046565b92915050565b5f60208284031215607d57607c6039565b5b5f6088848285016059565b91505092915050565b60ac8061009d5f395ff3fe6080604052348015600e575f80fd5b50600436106026575f3560e01c80633fa4f24514602a575b5f80fd5b60306044565b604051603b9190605f565b60405180910390f35b5f5481565b5f819050919050565b6059816049565b82525050565b5f60208201905060705f8301846052565b9291505056fea2646970667358221220998214425ddbe7b44d029d7605630645ac6aab8599e5f21172331c78392cee8264736f6c634300081a0033";

  it("Can deploy EVM contract", async () => {
    await enableEvmEmulation();

    const testInterface = new ethers.utils.Interface(testAbi);
    const factory = new ContractFactory(testInterface, testEvmBytecode);

    const contract = await factory.deploy(101);

    const testValue = await contract.value();

    expect(testValue).to.be.eq(101);
  });

});