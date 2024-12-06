import { expect } from "chai";
import { ethers, network } from "hardhat";
import type { Wallet } from "zksync-web3";
import type { L2BaseToken } from "../typechain";
import { L2BaseTokenFactory } from "../typechain";
import { deployContractOnAddress, getWallets, loadArtifact, provider } from "./shared/utils";
import type { BigNumber } from "ethers";
import { TEST_BOOTLOADER_FORMAL_ADDRESS, TEST_BASE_TOKEN_SYSTEM_CONTRACT_ADDRESS } from "./shared/constants";
import { prepareEnvironment, setResult } from "./shared/mocks";
import { randomBytes } from "crypto";
import { bech32, bech32m } from "bech32";
import bs58 from "bs58";

describe("L2BaseToken tests", () => {
  const richWallet = getWallets()[0];
  let wallets: Array<Wallet>;
  let L2BaseToken: L2BaseToken;
  let bootloaderAccount: ethers.Signer;
  let mailboxIface: ethers.utils.Interface;

  before(async () => {
    await prepareEnvironment();
    await deployContractOnAddress(TEST_BASE_TOKEN_SYSTEM_CONTRACT_ADDRESS, "L2BaseToken");
    L2BaseToken = L2BaseTokenFactory.connect(TEST_BASE_TOKEN_SYSTEM_CONTRACT_ADDRESS, richWallet);
    bootloaderAccount = await ethers.getImpersonatedSigner(TEST_BOOTLOADER_FORMAL_ADDRESS);
    mailboxIface = new ethers.utils.Interface((await loadArtifact("IMailbox")).abi);
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

  describe("mint", () => {
    it("called by bootlader", async () => {
      const initialSupply: BigNumber = await L2BaseToken.totalSupply();
      const initialBalanceOfWallet: BigNumber = await L2BaseToken.balanceOf(wallets[0].address);
      const amountToMint: BigNumber = ethers.utils.parseEther("10.0");

      await expect(L2BaseToken.connect(bootloaderAccount).mint(wallets[0].address, amountToMint))
        .to.emit(L2BaseToken, "Mint")
        .withArgs(wallets[0].address, amountToMint);

      const finalSupply: BigNumber = await L2BaseToken.totalSupply();
      const balanceOfWallet: BigNumber = await L2BaseToken.balanceOf(wallets[0].address);
      expect(finalSupply).to.equal(initialSupply.add(amountToMint));
      expect(balanceOfWallet).to.equal(initialBalanceOfWallet.add(amountToMint));
    });

    it("not called by bootloader", async () => {
      const amountToMint: BigNumber = ethers.utils.parseEther("10.0");
      await expect(L2BaseToken.connect(wallets[0]).mint(wallets[0].address, amountToMint)).to.be.rejectedWith(
        "Callable only by the bootloader"
      );
    });
  });

  describe("transfer", () => {
    it("transfer successfully", async () => {
      await (
        await L2BaseToken.connect(bootloaderAccount).mint(wallets[0].address, ethers.utils.parseEther("100.0"))
      ).wait();

      const senderBalanceBeforeTransfer: BigNumber = await L2BaseToken.balanceOf(wallets[0].address);
      const recipientBalanceBeforeTransfer: BigNumber = await L2BaseToken.balanceOf(wallets[1].address);

      const amountToTransfer = ethers.utils.parseEther("10.0");

      await expect(
        L2BaseToken.connect(bootloaderAccount).transferFromTo(wallets[0].address, wallets[1].address, amountToTransfer)
      )
        .to.emit(L2BaseToken, "Transfer")
        .withArgs(wallets[0].address, wallets[1].address, amountToTransfer);

      const senderBalanceAfterTransfer: BigNumber = await L2BaseToken.balanceOf(wallets[0].address);
      const recipientBalanceAfterTransfer: BigNumber = await L2BaseToken.balanceOf(wallets[1].address);
      expect(senderBalanceAfterTransfer).to.be.eq(senderBalanceBeforeTransfer.sub(amountToTransfer));
      expect(recipientBalanceAfterTransfer).to.be.eq(recipientBalanceBeforeTransfer.add(amountToTransfer));
    });

    it("no transfer due to insufficient balance", async () => {
      await (
        await L2BaseToken.connect(bootloaderAccount).mint(wallets[0].address, ethers.utils.parseEther("5.0"))
      ).wait();
      const amountToTransfer: BigNumber = ethers.utils.parseEther("6.0");

      await expect(
        L2BaseToken.connect(bootloaderAccount).transferFromTo(wallets[0].address, wallets[1].address, amountToTransfer)
      ).to.be.rejectedWith("Transfer amount exceeds balance");
    });

    it("no transfer - require special access", async () => {
      const maliciousWallet: Wallet = ethers.Wallet.createRandom().connect(provider);
      await (
        await L2BaseToken.connect(bootloaderAccount).mint(maliciousWallet.address, ethers.utils.parseEther("20.0"))
      ).wait();

      const amountToTransfer: BigNumber = ethers.utils.parseEther("20.0");

      await expect(
        L2BaseToken.connect(maliciousWallet).transferFromTo(
          maliciousWallet.address,
          wallets[1].address,
          amountToTransfer
        )
      ).to.be.rejectedWith("Only system contracts with special access can call this method");
    });
  });

  describe("balanceOf", () => {
    it("walletFrom address", async () => {
      const amountToMint: BigNumber = ethers.utils.parseEther("10.0");

      await L2BaseToken.connect(bootloaderAccount).mint(wallets[0].address, amountToMint);
      const balance = await L2BaseToken.balanceOf(wallets[0].address);
      expect(balance).to.equal(amountToMint);
    });

    it("address larger than 20 bytes", async () => {
      const amountToMint: BigNumber = ethers.utils.parseEther("123.0");

      const res = await L2BaseToken.connect(bootloaderAccount).mint(wallets[0].address, amountToMint);
      await res.wait();
      const largerAddress = ethers.BigNumber.from(
        "0x" + randomBytes(12).toString("hex") + wallets[0].address.slice(2)
      ).toHexString();
      const balance = await L2BaseToken.balanceOf(largerAddress);

      expect(balance).to.equal(amountToMint);
    });
  });

  describe("totalSupply", () => {
    it("correct total supply", async () => {
      const totalSupplyBefore = await L2BaseToken.totalSupply();
      const amountToMint: BigNumber = ethers.utils.parseEther("10.0");

      await L2BaseToken.connect(bootloaderAccount).mint(wallets[0].address, amountToMint);
      const totalSupply = await L2BaseToken.totalSupply();

      expect(totalSupply).to.equal(totalSupplyBefore.add(amountToMint));
    });
  });

  describe("name", () => {
    it("correct name", async () => {
      const name = await L2BaseToken.name();
      expect(name).to.equal("Bitcoin");
    });
  });

  describe("symbol", () => {
    it("correct symbol", async () => {
      const symbol = await L2BaseToken.symbol();
      expect(symbol).to.equal("BTC");
    });
  });

  describe("decimals", () => {
    it("correct decimals", async () => {
      const decimals = await L2BaseToken.decimals();
      expect(decimals).to.equal(8);
    });
  });

  describe("withdraw", () => {
    it("event, balance, totalsupply with P2PKH address", async () => {
      const amountToWithdraw: BigNumber = ethers.utils.parseEther("1.0");
      // Example Base58 address (P2PKH address)
      const base58Address = "1A1zP1eP5QGefi2DMPTfTL5SLmv7DivfNa";

      // Decode Base58 address to bytes
      const base85BtcAddressBytes = bs58.decode(base58Address);
      const hexString = ethers.utils.hexlify(base85BtcAddressBytes);
      const btcAddressBytes32 = ethers.utils.hexZeroPad(hexString, 32);

      const message: string = ethers.utils.solidityPack(
        ["bytes4", "bytes", "uint256"],
        [mailboxIface.getSighash("finalizeEthWithdrawal"), btcAddressBytes32, amountToWithdraw]
      );

      await setResult("L1Messenger", "sendToL1", [message], {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["bytes32"], [ethers.utils.keccak256(message)]),
      });

      // To prevent underflow since initial values are 0's and we are subtracting from them
      const amountToMint: BigNumber = ethers.utils.parseEther("100.0");
      await (await L2BaseToken.connect(bootloaderAccount).mint(L2BaseToken.address, amountToMint)).wait();

      const balanceBeforeWithdrawal: BigNumber = await L2BaseToken.balanceOf(L2BaseToken.address);
      const totalSupplyBefore = await L2BaseToken.totalSupply();

      await expect(L2BaseToken.connect(richWallet).withdraw(btcAddressBytes32, { value: amountToWithdraw }))
        .to.emit(L2BaseToken, "Withdrawal")
        .withArgs(richWallet.address, btcAddressBytes32, amountToWithdraw);

      const balanceAfterWithdrawal: BigNumber = await L2BaseToken.balanceOf(L2BaseToken.address);
      const totalSupplyAfter = await L2BaseToken.totalSupply();

      expect(balanceAfterWithdrawal).to.equal(balanceBeforeWithdrawal.sub(amountToWithdraw));
      expect(totalSupplyAfter).to.equal(totalSupplyBefore.sub(amountToWithdraw));
    });

    it("event, balance, totalsupply with Bech32 address", async () => {
      const amountToWithdraw: BigNumber = ethers.utils.parseEther("1.0");
      const bech32Address = "bc1qy82gaw2htfd5sslplpgmz4ktf9y3k7pac2226k0wljlmw3atfw5qwm4av4";
      const bech32DecodedAddress = bech32.decode(bech32Address, 90);
      // Extract the payload (excluding the witness first byte)
      const payload = bech32DecodedAddress.words.slice(1);
      // Convert the payload from words to bytes
      const payloadBytes = bech32.fromWords(payload);
      const hexString = ethers.utils.hexlify(payloadBytes);
      const btcAddressBytes32 = ethers.utils.hexZeroPad(hexString, 32);

      const message: string = ethers.utils.solidityPack(
        ["bytes4", "bytes", "uint256"],
        [mailboxIface.getSighash("finalizeEthWithdrawal"), btcAddressBytes32, amountToWithdraw]
      );

      await setResult("L1Messenger", "sendToL1", [message], {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["bytes32"], [ethers.utils.keccak256(message)]),
      });

      // To prevent underflow since initial values are 0's and we are subtracting from them
      const amountToMint: BigNumber = ethers.utils.parseEther("100.0");
      await (await L2BaseToken.connect(bootloaderAccount).mint(L2BaseToken.address, amountToMint)).wait();

      const balanceBeforeWithdrawal: BigNumber = await L2BaseToken.balanceOf(L2BaseToken.address);
      const totalSupplyBefore = await L2BaseToken.totalSupply();

      await expect(L2BaseToken.connect(richWallet).withdraw(btcAddressBytes32, { value: amountToWithdraw }))
        .to.emit(L2BaseToken, "Withdrawal")
        .withArgs(richWallet.address, btcAddressBytes32, amountToWithdraw);

      const balanceAfterWithdrawal: BigNumber = await L2BaseToken.balanceOf(L2BaseToken.address);
      const totalSupplyAfter = await L2BaseToken.totalSupply();

      expect(balanceAfterWithdrawal).to.equal(balanceBeforeWithdrawal.sub(amountToWithdraw));
      expect(totalSupplyAfter).to.equal(totalSupplyBefore.sub(amountToWithdraw));
    });

    it("event, balance, totalsupply with Bech32m address", async () => {
      const amountToWithdraw: BigNumber = ethers.utils.parseEther("1.0");
      const bech32mAddress = "bc1p5d7rjq7g6rdk2yhzks9smlaqtedr4dekq08ge8ztwac72sfr9rusxg3297";
      const bech32mDecodedAddress = bech32m.decode(bech32mAddress, 90);
      // Extract the payload (excluding the witness first byte)
      const payload = bech32mDecodedAddress.words.slice(1);
      // Convert the payload from words to bytes
      const payloadBytes = bech32.fromWords(payload);
      const hexString = ethers.utils.hexlify(payloadBytes);
      const btcAddressBytes32 = ethers.utils.hexZeroPad(hexString, 32);

      const message: string = ethers.utils.solidityPack(
        ["bytes4", "bytes", "uint256"],
        [mailboxIface.getSighash("finalizeEthWithdrawal"), btcAddressBytes32, amountToWithdraw]
      );

      await setResult("L1Messenger", "sendToL1", [message], {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["bytes32"], [ethers.utils.keccak256(message)]),
      });

      // To prevent underflow since initial values are 0's and we are subtracting from them
      const amountToMint: BigNumber = ethers.utils.parseEther("100.0");
      await (await L2BaseToken.connect(bootloaderAccount).mint(L2BaseToken.address, amountToMint)).wait();

      const balanceBeforeWithdrawal: BigNumber = await L2BaseToken.balanceOf(L2BaseToken.address);
      const totalSupplyBefore = await L2BaseToken.totalSupply();

      await expect(L2BaseToken.connect(richWallet).withdraw(btcAddressBytes32, { value: amountToWithdraw }))
        .to.emit(L2BaseToken, "Withdrawal")
        .withArgs(richWallet.address, btcAddressBytes32, amountToWithdraw);

      const balanceAfterWithdrawal: BigNumber = await L2BaseToken.balanceOf(L2BaseToken.address);
      const totalSupplyAfter = await L2BaseToken.totalSupply();

      expect(balanceAfterWithdrawal).to.equal(balanceBeforeWithdrawal.sub(amountToWithdraw));
      expect(totalSupplyAfter).to.equal(totalSupplyBefore.sub(amountToWithdraw));
    });

    it("event, balance, totalsupply, withdrawWithMessage", async () => {
      const amountToWithdraw: BigNumber = ethers.utils.parseEther("1.0");
      const additionalData: string = ethers.utils.defaultAbiCoder.encode(["string"], ["additional data"]);
      const message: string = ethers.utils.solidityPack(
        ["bytes4", "address", "uint256", "address", "bytes"],
        [
          mailboxIface.getSighash("finalizeEthWithdrawal"),
          wallets[1].address,
          amountToWithdraw,
          richWallet.address,
          additionalData,
        ]
      );

      await setResult("L1Messenger", "sendToL1", [message], {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["bytes32"], [ethers.utils.keccak256(message)]),
      });

      // Consistency reasons - won't crash if test order reverse
      const amountToMint: BigNumber = ethers.utils.parseEther("100.0");
      await (await L2BaseToken.connect(bootloaderAccount).mint(L2BaseToken.address, amountToMint)).wait();

      const totalSupplyBefore = await L2BaseToken.totalSupply();
      const balanceBeforeWithdrawal: BigNumber = await L2BaseToken.balanceOf(L2BaseToken.address);
      await expect(
        L2BaseToken.connect(richWallet).withdrawWithMessage(wallets[1].address, additionalData, {
          value: amountToWithdraw,
        })
      )
        .to.emit(L2BaseToken, "WithdrawalWithMessage")
        .withArgs(richWallet.address, wallets[1].address, amountToWithdraw, additionalData);
      const totalSupplyAfter = await L2BaseToken.totalSupply();
      const balanceAfterWithdrawal: BigNumber = await L2BaseToken.balanceOf(L2BaseToken.address);
      expect(balanceAfterWithdrawal).to.equal(balanceBeforeWithdrawal.sub(amountToWithdraw));
      expect(totalSupplyAfter).to.equal(totalSupplyBefore.sub(amountToWithdraw));
    });
  });
});
