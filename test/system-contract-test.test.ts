import { Wallet, utils } from "zksync-web3";
import * as hre from "hardhat";
import { Deployer } from "@matterlabs/hardhat-zksync-deploy";

import { TestSystemContract } from "../typechain-types/cache-zk/solpp-generated-contracts/test-contracts";
import { deployContractOnAddress } from "./utils/deployOnAnyAddress";
import { BigNumber, ethers } from "ethers";

const RICH_WALLET_PK = '0x7726827caac94a7f9e1b160f7ea819f172f7b6f9d2a97f992c38edeab82d4110';

describe('System contracts tests', function () {
    // An example address where our system contracts will be put
    const TEST_SYSTEM_CONTRACT_ADDRESS = '0x0000000000000000000000000000000000000101';
    let testContract: TestSystemContract;
    let deployer = new Deployer(hre, new Wallet(RICH_WALLET_PK));

    before('Prepare bootloader and system contracts', async function () {
        testContract = (await deployContractOnAddress(
            'TestSystemContract',
            TEST_SYSTEM_CONTRACT_ADDRESS,
            "0x",
            deployer
        )).connect(deployer.zkWallet) as TestSystemContract;

        await (await deployer.zkWallet.deposit({
            token: utils.ETH_ADDRESS,
            amount: ethers.utils.parseEther('10.0')
        })).wait();
    });

    it('Test precompile call', async function () {
        await testContract.testPrecompileCall();    
    })

    it('Test mimicCall and setValueForNextCall', async function () {
        const whoToMimic = Wallet.createRandom().address;
        const value = BigNumber.from(2).pow(128).sub(1);
        await (await testContract.testMimicCallAndValue(
            whoToMimic,
            value
        ));
    });

    it('Test onlySystemCall modifier', async function () {
        await testContract.testOnlySystemModifier();    
    });

    it('Test system mimicCall', async function () {
        await testContract.testSystemMimicCall();
    });
});
