import { ethers } from "hardhat";
import { enableEvmEmulation, getWallets } from "./shared/utils";
import { ContractFactory } from "ethers";
import { expect } from "chai";
import { ZERO_HASH } from "zksync-ethers/build/utils";

describe("EvmEmulation tests", function () {
  it("Can enable EVM emulation", async () => {
    await enableEvmEmulation();
  });

  const testAbi = [
    "constructor(uint256 initialValue)",
    "function value() view returns (uint)",
    "function testBlobBaseFee() view returns (uint)",
    "function testBlobHash(uint) view returns (bytes32)",
  ];

  const testEvmBytecode =
    "0x6080604052348015600e575f5ffd5b506040516102543803806102548339818101604052810190602e9190606b565b805f81905550506091565b5f5ffd5b5f819050919050565b604d81603d565b81146056575f5ffd5b50565b5f815190506065816046565b92915050565b5f60208284031215607d57607c6039565b5b5f6088848285016059565b91505092915050565b6101b68061009e5f395ff3fe608060405234801561000f575f5ffd5b506004361061003f575f3560e01c806307f641e7146100435780633fa4f24514610073578063f48357f114610091575b5f5ffd5b61005d600480360381019061005891906100fc565b6100af565b60405161006a919061013f565b60405180910390f35b61007b6100b9565b6040516100889190610167565b60405180910390f35b6100996100be565b6040516100a69190610167565b60405180910390f35b5f81499050919050565b5f5481565b5f4a905090565b5f5ffd5b5f819050919050565b6100db816100c9565b81146100e5575f5ffd5b50565b5f813590506100f6816100d2565b92915050565b5f60208284031215610111576101106100c5565b5b5f61011e848285016100e8565b91505092915050565b5f819050919050565b61013981610127565b82525050565b5f6020820190506101525f830184610130565b92915050565b610161816100c9565b82525050565b5f60208201905061017a5f830184610158565b9291505056fea2646970667358221220bb61c542ae87cd3f6b62191b5d02d7f434c16cd9302d721da9fb51a0faae845364736f6c634300081e0033";

  it("Can deploy EVM contract", async () => {
    await enableEvmEmulation();

    const wallet = getWallets()[0];

    const testInterface = new ethers.utils.Interface(testAbi);

    const factory = new ContractFactory(testInterface, testEvmBytecode, wallet);

    const contract = await factory.deploy(101);

    const testValue = await contract.value();

    expect(testValue).to.be.eq(101);
  });

  // TODO: anvil-zksync uses old EVM emulator
  it.skip("Can use BLOBBASEFEE opcode", async () => {
    await enableEvmEmulation();

    const testInterface = new ethers.utils.Interface(testAbi);

    const wallet = getWallets()[1];

    const factory = new ContractFactory(testInterface, testEvmBytecode, wallet);

    const contract = await factory.deploy(101);

    const testValue = await contract.testBlobBaseFee();

    expect(testValue).to.be.eq(1);
  });

  // TODO: anvil-zksync uses old EVM emulator
  it.skip("Can use BLOBHASH opcode", async () => {
    await enableEvmEmulation();

    const testInterface = new ethers.utils.Interface(testAbi);

    const wallet = getWallets()[2];

    const factory = new ContractFactory(testInterface, testEvmBytecode, wallet);

    const contract = await factory.deploy(101);

    const testValue = await contract.testBlobHash(0);

    expect(testValue).to.be.eq(ZERO_HASH);
  });
});
