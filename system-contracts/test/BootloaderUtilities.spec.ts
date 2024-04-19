import { expect } from "chai";
import { ethers } from "hardhat";
import type { Wallet } from "zksync-ethers";
import * as zksync from "zksync-ethers";
import { serialize } from "zksync-ethers/build/utils";
import type { BootloaderUtilities } from "../typechain";
import { BootloaderUtilitiesFactory } from "../typechain";
import { TEST_BOOTLOADER_UTILITIES_ADDRESS } from "./shared/constants";
import { signedTxToTransactionData } from "./shared/transactions";
import { deployContractOnAddress, getWallets } from "./shared/utils";

describe("BootloaderUtilities tests", function () {
  let wallet: Wallet;
  let bootloaderUtilities: BootloaderUtilities;

  before(async () => {
    wallet = getWallets()[0];
    await deployContractOnAddress(TEST_BOOTLOADER_UTILITIES_ADDRESS, "BootloaderUtilities");
    bootloaderUtilities = BootloaderUtilitiesFactory.connect(TEST_BOOTLOADER_UTILITIES_ADDRESS, wallet);
  });

  describe("EIP-712 transaction", function () {
    it("check hashes", async () => {
      const eip712Tx = await wallet.populateTransaction({
        type: 113,
        to: wallet.address,
        from: wallet.address,
        data: "0x",
        value: 0,
        customData: {
          gasPerPubdata: zksync.utils.DEFAULT_GAS_PER_PUBDATA_LIMIT,
        },
      });
      const signedEip712Tx = await wallet.signTransaction(eip712Tx);
      const parsedEIP712tx = zksync.utils.parseTransaction(signedEip712Tx);
      const eip712TxData = signedTxToTransactionData(parsedEIP712tx)!;
      const expectedEIP712TxHash = parsedEIP712tx.hash;
      const expectedEIP712SignedHash = zksync.EIP712Signer.getSignedDigest(eip712Tx);

      const proposedEIP712Hashes = await bootloaderUtilities.getTransactionHashes(eip712TxData);

      expect(proposedEIP712Hashes.txHash).to.be.eq(expectedEIP712TxHash);
      expect(proposedEIP712Hashes.signedTxHash).to.be.eq(expectedEIP712SignedHash);
    });
  });

  describe("legacy transaction", function () {
    it("check hashes", async () => {
      const legacyTx = await wallet.populateTransaction({
        type: 0,
        to: wallet.address,
        from: wallet.address,
        data: "0x",
        value: 0,
        gasLimit: 50000,
      });
      const txBytes = await wallet.signTransaction(legacyTx);
      const parsedTx = zksync.utils.parseTransaction(txBytes);
      const txData = signedTxToTransactionData(parsedTx)!;

      const expectedTxHash = parsedTx.hash;
      delete legacyTx.from;
      const expectedSignedHash = ethers.utils.keccak256(serialize(legacyTx));

      const proposedHashes = await bootloaderUtilities.getTransactionHashes(txData);
      expect(proposedHashes.txHash).to.be.eq(expectedTxHash);
      expect(proposedHashes.signedTxHash).to.be.eq(expectedSignedHash);
    });

    it("invalid v signature value", async () => {
      const legacyTx = await wallet.populateTransaction({
        type: 0,
        to: wallet.address,
        from: wallet.address,
        data: "0x",
        value: 0,
        gasLimit: 50000,
      });
      const txBytes = await wallet.signTransaction(legacyTx);
      const parsedTx = zksync.utils.parseTransaction(txBytes);
      const txData = signedTxToTransactionData(parsedTx)!;

      const signature = ethers.utils.arrayify(txData.signature);
      signature[64] = 29;
      txData.signature = signature;

      await expect(bootloaderUtilities.getTransactionHashes(txData)).to.be.revertedWith("Invalid v value");
    });
  });

  describe("EIP-1559 transaction", function () {
    it("check hashes", async () => {
      const eip1559Tx = await wallet.populateTransaction({
        type: 2,
        to: wallet.address,
        from: wallet.address,
        data: "0x",
        value: 0,
        maxFeePerGas: 12000,
        maxPriorityFeePerGas: 100,
      });
      const signedEip1559Tx = await wallet.signTransaction(eip1559Tx);
      const parsedEIP1559tx = zksync.utils.parseTransaction(signedEip1559Tx);

      const EIP1559TxData = signedTxToTransactionData(parsedEIP1559tx)!;
      delete eip1559Tx.from;
      const expectedEIP1559TxHash = parsedEIP1559tx.hash;
      const expectedEIP1559SignedHash = ethers.utils.keccak256(serialize(eip1559Tx));

      const proposedEIP1559Hashes = await bootloaderUtilities.getTransactionHashes(EIP1559TxData);
      expect(proposedEIP1559Hashes.txHash).to.be.eq(expectedEIP1559TxHash);
      expect(proposedEIP1559Hashes.signedTxHash).to.be.eq(expectedEIP1559SignedHash);
    });

    it("invalid v signature value", async () => {
      const eip1559Tx = await wallet.populateTransaction({
        type: 2,
        to: wallet.address,
        from: wallet.address,
        data: "0x",
        value: 0,
        maxFeePerGas: 12000,
        maxPriorityFeePerGas: 100,
      });
      const signedEip1559Tx = await wallet.signTransaction(eip1559Tx);
      const parsedEIP1559tx = zksync.utils.parseTransaction(signedEip1559Tx);

      const EIP1559TxData = signedTxToTransactionData(parsedEIP1559tx)!;
      const signature = ethers.utils.arrayify(EIP1559TxData.signature);
      signature[64] = 0;
      EIP1559TxData.signature = signature;

      await expect(bootloaderUtilities.getTransactionHashes(EIP1559TxData)).to.be.revertedWith("Invalid v value");
    });
  });

  describe("EIP-1559 transaction", function () {
    it("check hashes", async () => {
      const eip2930Tx = await wallet.populateTransaction({
        type: 1,
        to: wallet.address,
        from: wallet.address,
        data: "0x",
        value: 0,
        gasLimit: 50000,
        gasPrice: 55000,
      });
      const signedEip2930Tx = await wallet.signTransaction(eip2930Tx);
      const parsedEIP2930tx = zksync.utils.parseTransaction(signedEip2930Tx);

      const EIP2930TxData = signedTxToTransactionData(parsedEIP2930tx)!;
      delete eip2930Tx.from;
      const expectedEIP2930TxHash = parsedEIP2930tx.hash;
      const expectedEIP2930SignedHash = ethers.utils.keccak256(serialize(eip2930Tx));

      const proposedEIP2930Hashes = await bootloaderUtilities.getTransactionHashes(EIP2930TxData);
      expect(proposedEIP2930Hashes.txHash).to.be.eq(expectedEIP2930TxHash);
      expect(proposedEIP2930Hashes.signedTxHash).to.be.eq(expectedEIP2930SignedHash);
    });

    it("invalid v signature value", async () => {
      const eip2930Tx = await wallet.populateTransaction({
        type: 1,
        to: wallet.address,
        from: wallet.address,
        data: "0x",
        value: 0,
        gasLimit: 50000,
        gasPrice: 55000,
      });
      const signedEip2930Tx = await wallet.signTransaction(eip2930Tx);
      const parsedEIP2930tx = zksync.utils.parseTransaction(signedEip2930Tx);

      const EIP2930TxData = signedTxToTransactionData(parsedEIP2930tx)!;
      const signature = ethers.utils.arrayify(EIP2930TxData.signature);
      signature[64] = 100;
      EIP2930TxData.signature = signature;

      await expect(bootloaderUtilities.getTransactionHashes(EIP2930TxData)).to.be.revertedWith("Invalid v value");
    });
  });
});
