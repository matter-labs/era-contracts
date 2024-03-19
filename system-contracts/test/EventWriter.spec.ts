import { expect } from "chai";
import { ethers } from "hardhat";
import type { Wallet } from "zksync-ethers";
import { Contract } from "zksync-ethers";
import type { TransactionResponse } from "zksync-web3/build/src/types";
import { ONE_BYTES32_HEX, REAL_EVENT_WRITER_CONTRACT_ADDRESS } from "./shared/constants";
import { EXTRA_ABI_CALLER_ADDRESS, encodeExtraAbiCallerCalldata } from "./shared/extraAbiCaller";
import { getCode, getWallets, loadYulBytecode, loadZasmBytecode, setCode } from "./shared/utils";

describe("EventWriter tests", function () {
  let wallet: Wallet;

  let eventWriter: Contract;
  let extraAbiCaller: Contract;

  let realEventWriterBytecode: string;

  before(async () => {
    wallet = getWallets()[0];

    realEventWriterBytecode = await getCode(REAL_EVENT_WRITER_CONTRACT_ADDRESS);

    const eventWriterBytecode = loadYulBytecode("EventWriter", "");
    await setCode(REAL_EVENT_WRITER_CONTRACT_ADDRESS, eventWriterBytecode);
    eventWriter = new Contract(REAL_EVENT_WRITER_CONTRACT_ADDRESS, [], wallet);

    const extraAbiCallerBytecode = await loadZasmBytecode("ExtraAbiCaller", "test-contracts");
    await setCode(EXTRA_ABI_CALLER_ADDRESS, extraAbiCallerBytecode);
    extraAbiCaller = new Contract(EXTRA_ABI_CALLER_ADDRESS, [], wallet);
  });

  after(async () => {
    await setCode(REAL_EVENT_WRITER_CONTRACT_ADDRESS, realEventWriterBytecode);
  });

  it("non system call failed", async () => {
    await expect(eventWriter.fallback({ data: "0x" })).to.be.reverted;
  });

  it("zero topics", async () => {
    const txResponse = await extraAbiCaller.fallback({
      data: encodeExtraAbiCallerCalldata(REAL_EVENT_WRITER_CONTRACT_ADDRESS, 0, [0], "0x"),
    });
    expect(await checkReturnedEvent(txResponse, extraAbiCaller.address, [], "0x")).to.be.eq(true);
  });

  it("one topic", async () => {
    const txResponse = await extraAbiCaller.fallback({
      data: encodeExtraAbiCallerCalldata(
        REAL_EVENT_WRITER_CONTRACT_ADDRESS,
        0,
        [1, "0x1234567890123456789012345678901234567890123456789012345678901234"],
        "0xdeadbeef"
      ),
    });
    expect(
      await checkReturnedEvent(
        txResponse,
        extraAbiCaller.address,
        ["0x1234567890123456789012345678901234567890123456789012345678901234"],
        "0xdeadbeef"
      )
    ).to.be.eq(true);
  });

  it("two topics", async () => {
    const txResponse = await extraAbiCaller.fallback({
      data: encodeExtraAbiCallerCalldata(
        REAL_EVENT_WRITER_CONTRACT_ADDRESS,
        0,
        [
          2,
          "0x1234567890123456789012345678901234567890123456789012345678901234",
          "0x1278378123784223232874782378478237848723784782378423747237848723",
        ],
        "0xabcd"
      ),
    });
    expect(
      await checkReturnedEvent(
        txResponse,
        extraAbiCaller.address,
        [
          "0x1234567890123456789012345678901234567890123456789012345678901234",
          "0x1278378123784223232874782378478237848723784782378423747237848723",
        ],
        "0xabcd"
      )
    ).to.be.eq(true);
  });

  it("three topics", async () => {
    const txResponse = await extraAbiCaller.fallback({
      data: encodeExtraAbiCallerCalldata(
        REAL_EVENT_WRITER_CONTRACT_ADDRESS,
        0,
        [
          3,
          "0x1234567890123456789012345678901234567890123456789012345678901234",
          "0x1278378123784223232874782378478237848723784782378423747237848723",
          ethers.constants.HashZero,
        ],
        "0x"
      ),
    });
    expect(
      await checkReturnedEvent(
        txResponse,
        extraAbiCaller.address,
        [
          "0x1234567890123456789012345678901234567890123456789012345678901234",
          "0x1278378123784223232874782378478237848723784782378423747237848723",
          ethers.constants.HashZero,
        ],
        "0x"
      )
    ).to.be.eq(true);
  });

  it("four topics", async () => {
    const txResponse = await extraAbiCaller.fallback({
      data: encodeExtraAbiCallerCalldata(
        REAL_EVENT_WRITER_CONTRACT_ADDRESS,
        0,
        [
          4,
          ONE_BYTES32_HEX,
          "0x1234567890123456789012345678901234567890123456789012345678901234",
          "0x1278378123784223232874782378478237848723784782378423747237848723",
          ethers.constants.HashZero,
        ],
        "0x2828383489438934898934893894893895348915893489589348958349589348958934859348958934858394589348958934854385838954893489"
      ),
    });
    expect(
      await checkReturnedEvent(
        txResponse,
        extraAbiCaller.address,
        [
          ONE_BYTES32_HEX,
          "0x1234567890123456789012345678901234567890123456789012345678901234",
          "0x1278378123784223232874782378478237848723784782378423747237848723",
          ethers.constants.HashZero,
        ],
        "0x2828383489438934898934893894893895348915893489589348958349589348958934859348958934858394589348958934854385838954893489"
      )
    ).to.be.eq(true);
  });

  it("five topics failed", async () => {
    await expect(
      extraAbiCaller.fallback({
        data: encodeExtraAbiCallerCalldata(
          REAL_EVENT_WRITER_CONTRACT_ADDRESS,
          0,
          [5, ONE_BYTES32_HEX, ONE_BYTES32_HEX, ONE_BYTES32_HEX, ONE_BYTES32_HEX, ONE_BYTES32_HEX],
          "0x"
        ),
      })
    ).to.be.reverted;
  });
});

async function checkReturnedEvent(
  txResponse: TransactionResponse,
  address: string,
  topics: string[],
  data: string
): boolean {
  const receipt = await txResponse.wait();
  const eventsFromAddress = receipt.logs.filter((log) => log.address.toLowerCase() === address.toLowerCase());
  if (eventsFromAddress.length !== 1) {
    return false;
  }
  const foundEvent = eventsFromAddress[0];
  if (foundEvent.topics.length !== topics.length) {
    return false;
  }
  for (let i = 0; i < topics.length; i++) {
    if (topics[i].toLowerCase() !== foundEvent.topics[i].toLowerCase()) {
      return false;
    }
  }
  if (foundEvent.data.toLowerCase() !== data.toLowerCase()) {
    return false;
  }
  return true;
}
