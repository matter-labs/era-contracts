import { expect } from "chai";
import type { Wallet } from "zksync-web3";
import { Contract } from "zksync-web3";
import { Language } from "../scripts/constants";
import { readYulBytecode } from "../scripts/utils";
import type { EventWriterTest } from "../typechain";
import { EVENT_WRITER_CONTRACT_ADDRESS } from "./shared/constants";
import { deployContract, getCode, getWallets, setCode } from "./shared/utils";

describe("EventWriter tests", function () {
  let wallet: Wallet;
  let eventWriter: Contract;
  let eventWriterTest: EventWriterTest;

  let _eventWriterCode: string;

  before(async () => {
    _eventWriterCode = await getCode(EVENT_WRITER_CONTRACT_ADDRESS);
    const eventWriterTestCode = readYulBytecode({
      codeName: "EventWriter",
      path: "",
      lang: Language.Yul,
      address: ethers.constants.AddressZero,
    });
    await setCode(EVENT_WRITER_CONTRACT_ADDRESS, eventWriterTestCode);

    wallet = (await getWallets())[0];
    eventWriter = new Contract(EVENT_WRITER_CONTRACT_ADDRESS, [], wallet);
    eventWriterTest = (await deployContract("EventWriterTest")) as EventWriterTest;
  });

  after(async () => {
    await setCode(EVENT_WRITER_CONTRACT_ADDRESS, _eventWriterCode);
  });

  it("non system call failed", async () => {
    await expect(eventWriter.fallback({ data: "0x" })).to.be.reverted;
  });

  // TODO: anonymous events doesn't work
  it.skip("zero topics", async () => {
    console.log((await (await eventWriterTest.zeroTopics("0x")).wait()).events);
    await expect(eventWriterTest.zeroTopics("0x")).to.emit(eventWriterTest, "ZeroTopics").withArgs("0x");
  });

  it("one topic", async () => {
    await expect(eventWriterTest.oneTopic("0xdeadbeef")).to.emit(eventWriterTest, "OneTopic").withArgs("0xdeadbeef");
  });

  it("two topics", async () => {
    await expect(
      eventWriterTest.twoTopics("0x1278378123784223232874782378478237848723784782378423747237848723", "0xabcd")
    )
      .to.emit(eventWriterTest, "TwoTopics")
      .withArgs("0x1278378123784223232874782378478237848723784782378423747237848723", "0xabcd");
  });

  it("three topics", async () => {
    await expect(eventWriterTest.threeTopics(0, 1133, "0x"))
      .to.emit(eventWriterTest, "ThreeTopics")
      .withArgs(0, 1133, "0x");
  });

  it("four topics", async () => {
    await expect(
      eventWriterTest.fourTopics(
        "0x1234567890",
        0,
        22,
        "0x2828383489438934898934893894893895348915893489589348958349589348958934859348958934858394589348958934854385838954893489"
      )
    )
      .to.emit(eventWriterTest, "FourTopics")
      .withArgs(
        "0x1234567890",
        0,
        22,
        "0x2828383489438934898934893894893895348915893489589348958349589348958934859348958934858394589348958934854385838954893489"
      );
  });
});
