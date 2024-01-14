import { ethers, network } from "hardhat";
import { SystemContext, SystemContextFactory } from "../typechain";
import { TEST_BOOTLOADER_FORMAL_ADDRESS, TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS } from "./shared/constants";
import { deployContractOnAddress, getWallets, provider } from "./shared/utils";
import { prepareEnvironment } from "./shared/mocks";
import { expect } from "chai";
import { Wallet } from "zksync-web3";


describe("SystemContext tests", () => {
    const wallet = getWallets()[0];
    let wallets: Array<Wallet>;
    let systemContext: SystemContext;
    let bootloaderAccount: ethers.Signer;
    
    before(async () => {
        await prepareEnvironment();
        await deployContractOnAddress(TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS, "SystemContext");
        systemContext = SystemContextFactory.connect(TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS, wallet);
        bootloaderAccount = await ethers.getImpersonatedSigner(TEST_BOOTLOADER_FORMAL_ADDRESS);
    });

    beforeEach(async () => {
        wallets = Array.from({ length: 2 }, () => ethers.Wallet.createRandom().connect(provider));
      });

    after(async function () {
        await network.provider.request({
          method: "hardhat_stopImpersonatingAccount",
          params: [TEST_BOOTLOADER_FORMAL_ADDRESS],
        });
      });

      describe("setTxOrigin", async () => {
        it("should revert not called by bootlader", async () => {
            const txOriginExpected = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
            await expect(systemContext.setTxOrigin(txOriginExpected))
            .to.be.rejectedWith("Callable only by the bootloader");
      });

        it("should set tx.origin", async () => {
          const txOriginBefore = await systemContext.origin(); 
          const txOriginExpected = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
          await systemContext.connect(bootloaderAccount).setTxOrigin(txOriginExpected);
          const result = (await systemContext.origin()).toLowerCase();
          expect(result).to.be.equal(txOriginExpected);
          expect(result).to.be.not.equal(txOriginBefore);
        });
    });

    describe("setGasPrice", async () => {
        it("should revert not called by bootlader", async () => {
            const newGasPrice = 4294967295;
            await expect(systemContext.setGasPrice(newGasPrice))
            .to.be.rejectedWith("Callable only by the bootloader");
      });

        it("should set tx.gasprice", async () => {
          const gasPriceBefore = await systemContext.gasPrice(); 
          const gasPriceExpected = 4294967295;
          await systemContext.connect(bootloaderAccount).setGasPrice(gasPriceExpected);
          const result = (await systemContext.gasPrice());
          expect(result).to.be.equal(gasPriceExpected);
          expect(result).to.be.not.equal(gasPriceBefore);
        });
    });

    describe("getBlockHashEVM", async () => {
        it("should return 0, block number out of 256-block supported range", async () => {
            const blockNumber = 257;
            const result = await systemContext.getBlockHashEVM(blockNumber);
            expect(result).to.equal(ethers.constants.HashZero);
        });  
    });
});