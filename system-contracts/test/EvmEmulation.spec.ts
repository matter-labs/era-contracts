import { ethers } from "hardhat";
import { enableEvmEmulation, getWallets } from "./shared/utils";
import { ContractFactory } from "ethers";
import type { Contract } from "ethers";
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

  // BLOBBASEFEE is currently unsupported by ZKsync's EVM bytecode interpreter.
  // Re-enable only if interpreter support is added and the runner can validate the expected blob base fee.
  it.skip("Can use BLOBBASEFEE opcode", async () => {
    await enableEvmEmulation();

    const testInterface = new ethers.utils.Interface(testAbi);

    const wallet = getWallets()[1];

    const factory = new ContractFactory(testInterface, testEvmBytecode, wallet);

    const contract = await factory.deploy(101);

    const testValue = await contract.testBlobBaseFee();

    expect(testValue).to.be.eq(1);
  });

  // BLOBHASH is currently unsupported by ZKsync's EVM bytecode interpreter.
  // Re-enable only if interpreter support is added and the runner can validate the expected blob hash value.
  it.skip("Can use BLOBHASH opcode", async () => {
    await enableEvmEmulation();

    const testInterface = new ethers.utils.Interface(testAbi);

    const wallet = getWallets()[2];

    const factory = new ContractFactory(testInterface, testEvmBytecode, wallet);

    const contract = await factory.deploy(101);

    const testValue = await contract.testBlobHash(0);

    expect(testValue).to.be.eq(ZERO_HASH);
  });

  // A zero-length memory access is a legal no-op at any offset on EVM, so the emulator does not
  // validate the offset when the length is zero. Such an offset must therefore never reach an
  // EraVM heap pointer: it comes straight from the stack and wraps modulo 2**256, so it can land
  // outside the uint32 range EraVM allows, or inside the emulator's own memory region.
  // Source: test/evm-contracts/ZeroLenMemoryOffset.sol
  const zeroLenMemoryOffsetAbi = [
    "function testCalldataCopy(uint256) pure returns (uint256)",
    "function testCodeCopy(uint256) pure returns (uint256)",
    "function testMcopy(uint256) pure returns (uint256)",
    "function testReturndataCopy(uint256) pure returns (uint256)",
    "function testExtCodeCopy(address,uint256) view returns (uint256)",
    "function testCall(address,uint256) returns (uint256)",
    "function testStaticCall(address,uint256) view returns (uint256)",
    "function testDelegateCall(address,uint256) returns (uint256)",
    "function testCreate(uint256) returns (uint256)",
    "function testCreate2(uint256) returns (uint256)",
  ];

  const zeroLenMemoryOffsetBytecode =
    "0x6080604052348015600e575f5ffd5b506104b08061001c5f395ff3fe608060405234801561000f575f5ffd5b506004361061009c575f3560e01c80637175eb6e116100645780637175eb6e14610190578063b505dee5146101c0578063c0e8fa14146101f0578063c3ffae7314610220578063da5dd8b8146102505761009c565b80630ee006ad146100a05780631049ef49146100d057806328ee2238146101005780635446d32b1461013057806359c75ada14610160575b5f5ffd5b6100ba60048036038101906100b5919061038f565b610280565b6040516100c791906103c9565b60405180910390f35b6100ea60048036038101906100e5919061038f565b610290565b6040516100f791906103c9565b60405180910390f35b61011a6004803603810190610115919061043c565b6102a0565b60405161012791906103c9565b60405180910390f35b61014a6004803603810190610145919061038f565b6102b2565b60405161015791906103c9565b60405180910390f35b61017a6004803603810190610175919061043c565b6102cb565b60405161018791906103c9565b60405180910390f35b6101aa60048036038101906101a5919061038f565b6102e8565b6040516101b791906103c9565b60405180910390f35b6101da60048036038101906101d5919061038f565b6102f8565b6040516101e791906103c9565b60405180910390f35b61020a6004803603810190610205919061038f565b610310565b60405161021791906103c9565b60405180910390f35b61023a6004803603810190610235919061043c565b610320565b60405161024791906103c9565b60405180910390f35b61026a6004803603810190610265919061043c565b61033c565b60405161027791906103c9565b60405180910390f35b5f5f5f833e62c0ffee9050919050565b5f5f5f833762c0ffee9050919050565b5f5f5f83853c62c0ffee905092915050565b5f5f5f835ff56102c0575f5ffd5b62c0ffee9050919050565b5f5f825f845f875af16102dc575f5ffd5b62c0ffee905092915050565b5f5f82835e62c0ffee9050919050565b5f5f825ff0610305575f5ffd5b62c0ffee9050919050565b5f5f5f833962c0ffee9050919050565b5f5f825f84865af4610330575f5ffd5b62c0ffee905092915050565b5f5f825f84865afa61034c575f5ffd5b62c0ffee905092915050565b5f5ffd5b5f819050919050565b61036e8161035c565b8114610378575f5ffd5b50565b5f8135905061038981610365565b92915050565b5f602082840312156103a4576103a3610358565b5b5f6103b18482850161037b565b91505092915050565b6103c38161035c565b82525050565b5f6020820190506103dc5f8301846103ba565b92915050565b5f73ffffffffffffffffffffffffffffffffffffffff82169050919050565b5f61040b826103e2565b9050919050565b61041b81610401565b8114610425575f5ffd5b50565b5f8135905061043681610412565b92915050565b5f5f6040838503121561045257610451610358565b5b5f61045f85828601610428565b92505060206104708582860161037b565b915050925092905056fea2646970667358221220af034bc6d9eede734345c05958b0478523a87757598078fd7848b3105b2d707564736f6c634300081c0033";

  const MARKER = 0xc0ffee;
  // Exercises the empty-account call path.
  const EMPTY_ACCOUNT = "0x00000000000000000000000000000000deadbeef";
  // Exercises modexpGasCost(), which reads the argument offset directly with MLOAD.
  const MODEXP_PRECOMPILE = "0x0000000000000000000000000000000000000005";

  describe("Zero-length memory access at an unvalidated offset", function () {
    let contract: Contract;

    before(async () => {
      await enableEvmEmulation();

      const wallet = getWallets()[0];
      const factory = new ContractFactory(
        new ethers.utils.Interface(zeroLenMemoryOffsetAbi),
        zeroLenMemoryOffsetBytecode,
        wallet
      );

      contract = await factory.deploy();
    });

    const OFFSETS: [string, ethers.BigNumber][] = [
      // Above uint32: MEM_OFFSET() + offset cannot be a valid EraVM heap pointer.
      ["2**32", ethers.BigNumber.from(2).pow(32)],
      ["2**200", ethers.BigNumber.from(2).pow(200)],
      // Wraps modulo 2**256 so that MEM_OFFSET() + offset == 0, the base of the region the
      // emulator uses for its own scratch space rather than for emulated EVM memory.
      ["2**256 - MEM_OFFSET()", ethers.constants.MaxUint256.sub(33919)],
    ];

    for (const [label, offset] of OFFSETS) {
      describe(`offset ${label}`, function () {
        for (const name of ["testCalldataCopy", "testCodeCopy", "testMcopy", "testReturndataCopy"] as const) {
          it(`${name} succeeds`, async () => {
            expect(await contract[name](offset)).to.be.eq(MARKER);
          });
        }

        for (const target of [EMPTY_ACCOUNT, MODEXP_PRECOMPILE]) {
          it(`testExtCodeCopy succeeds for ${target}`, async () => {
            expect(await contract.testExtCodeCopy(target, offset)).to.be.eq(MARKER);
          });

          it(`testStaticCall succeeds for ${target}`, async () => {
            expect(await contract.testStaticCall(target, offset)).to.be.eq(MARKER);
          });

          // State-changing, so assert on the receipt as well as on the returned marker.
          it(`testCall succeeds for ${target}`, async () => {
            expect(await contract.callStatic.testCall(target, offset)).to.be.eq(MARKER);
            expect((await (await contract.testCall(target, offset)).wait()).status).to.be.eq(1);
          });

          it(`testDelegateCall succeeds for ${target}`, async () => {
            expect(await contract.callStatic.testDelegateCall(target, offset)).to.be.eq(MARKER);
            expect((await (await contract.testDelegateCall(target, offset)).wait()).status).to.be.eq(1);
          });
        }

        for (const name of ["testCreate", "testCreate2"] as const) {
          it(`${name} succeeds`, async () => {
            expect((await (await contract[name](offset)).wait()).status).to.be.eq(1);
          });
        }
      });
    }
  });
});
