import { expect } from "chai";
import { ethers, network } from "hardhat";
import type { Wallet } from "zksync-ethers";
import type { PubdataChunkPublisher } from "../typechain";
import { PubdataChunkPublisherFactory } from "../typechain";
import { TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, TEST_PUBDATA_CHUNK_PUBLISHER_ADDRESS } from "./shared/constants";
import { prepareEnvironment } from "./shared/mocks";
import { deployContractOnAddress, getWallets } from "./shared/utils";

describe("PubdataChunkPublisher tests", () => {
  let wallet: Wallet;
  let l1MessengerAccount: ethers.Signer;

  let pubdataChunkPublisher: PubdataChunkPublisher;

  const genRandHex = (size) => ethers.utils.hexlify(ethers.utils.randomBytes(size));

  const blobSizeInBytes = 126_976;
  const maxNumberBlobs = 6;

  before(async () => {
    await prepareEnvironment();
    wallet = getWallets()[0];

    await deployContractOnAddress(TEST_PUBDATA_CHUNK_PUBLISHER_ADDRESS, "PubdataChunkPublisher");
    pubdataChunkPublisher = PubdataChunkPublisherFactory.connect(TEST_PUBDATA_CHUNK_PUBLISHER_ADDRESS, wallet);

    l1MessengerAccount = await ethers.getImpersonatedSigner(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS);
  });

  after(async () => {
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS],
    });
  });

  describe("chunkPubdataToBlobs", () => {
    it("Too Much Pubdata", async () => {
      const pubdata = genRandHex(blobSizeInBytes * maxNumberBlobs + 1);
      await expect(
        pubdataChunkPublisher.connect(l1MessengerAccount).chunkPubdataToBlobs(pubdata)
      ).to.be.revertedWithCustomError(pubdataChunkPublisher, "TooMuchPubdata");
    });

    it("Publish 1 Blob", async () => {
      const pubdata = genRandHex(blobSizeInBytes);
      await pubdataChunkPublisher.connect(l1MessengerAccount).chunkPubdataToBlobs(pubdata);
    });

    it("Publish 2 Blobs", async () => {
      const pubdata = genRandHex(blobSizeInBytes * maxNumberBlobs);
      await pubdataChunkPublisher.connect(l1MessengerAccount).chunkPubdataToBlobs(pubdata);
    });
  });
});
