import { ethers, network } from "hardhat";
import type { InteropHandler } from "../typechain";
import { IL2DAValidatorFactory } from "../typechain/IL2DAValidatorFactory";
import { L1MessengerFactory } from "../typechain";
import { prepareEnvironment, setResult } from "./shared/mocks";
import { deployContractOnAddress, getCode, getWallets } from "./shared/utils";
import { utils, L2VoidSigner } from "zksync-ethers";
import type { Wallet } from "zksync-ethers";
import {
  TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS,
  TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS,
  TEST_BOOTLOADER_FORMAL_ADDRESS,
  TEST_L2_INTEROP_HANDLER_ADDRESS,
} from "./shared/constants";
import { expect } from "chai";
import { randomBytes } from "crypto";

const EXPECTED_DA_INPUT_OFFSET = 160;
const L2_TO_L1_LOGS_MERKLE_TREE_LEAVES = 16_384;
const L2_TO_L1_LOG_SERIALIZE_SIZE = 88;
const L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH = "0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba";

describe("InteropHandler tests", () => {
  let interopHandler: InteropHandler;
  let wallet: Wallet;
  let l1MessengerAccount: ethers.Signer;
  let bootloaderAccount: ethers.Signer;

  before(async () => {});

  it("should mint base token", async () => {
    // set numberOfLogsBytes to 0x4002 to trigger the revert (max value is 0x4000)
    // await expect(
    //   interopHandler
    //     .connect(bootloaderAccount)
    //     .publishPubdataAndClearState(
    //       ethers.constants.AddressZero,
    //       await emulator.buildTotalL2ToL1PubdataAndStateDiffs(l1Messenger, { numberOfLogs: 0x4002 })
    //     )
    // ).to.be.revertedWithCustomError(l1Messenger, "ReconstructionMismatch");
  });

  it("should send value token", async () => {
    // set numberOfLogsBytes to 0x4002 to trigger the revert (max value is 0x4000)
    // await expect(
    //   interopHandler
    //     .connect(bootloaderAccount)
    //     .publishPubdataAndClearState(
    //       ethers.constants.AddressZero,
    //       await emulator.buildTotalL2ToL1PubdataAndStateDiffs(l1Messenger, { numberOfLogs: 0x4002 })
    //     )
    // ).to.be.revertedWithCustomError(l1Messenger, "ReconstructionMismatch");
    // await wallet.sendTransaction({
    //     type: 113,
    //     to: TEST_L2_INTEROP_HANDLER_ADDRESS,
    //     data: "0x",
    //     customData: {
    //       factoryDeps: [ethers.utils.hexlify(bytecode)],
    //       gasPerPubdata: 50000,
    //     },
    //   });
  });
});
