import { expect } from 'chai';
import { ethers } from 'ethers';
import * as hardhat from 'hardhat';
import { REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT } from 'zksync-web3/build/src/utils';
import { IZkSync, IZkSyncFactory } from 'zksync-web3/build/typechain';
import { Action, diamondCut, facetCut } from '../../src.ts/diamondCut';
import {
    AllowList,
    AllowListFactory,
    DiamondInitFactory,
    GettersFacetFactory,
    MailboxFacetFactory,
    TestnetERC20Token,
    TestnetERC20TokenFactory
} from '../../typechain';
import { IL1Bridge } from '../../typechain/IL1Bridge';
import { IL1BridgeFactory } from '../../typechain/IL1BridgeFactory';
import { AccessMode, getCallRevertReason } from './utils';

describe(`L1ERC20Bridge tests`, function () {
    let owner: ethers.Signer;
    let randomSigner: ethers.Signer;
    let allowList: AllowList;
    let l1ERC20Bridge: IL1Bridge;
    let erc20TestToken: TestnetERC20Token;
    let testnetERC20TokenContract: ethers.Contract;
    let l1Erc20BridgeContract: ethers.Contract;
    let zksyncContract: IZkSync;

    before(async () => {
        [owner, randomSigner] = await hardhat.ethers.getSigners();

        const gettersFactory = await hardhat.ethers.getContractFactory(`GettersFacet`);
        const gettersContract = await gettersFactory.deploy();
        const gettersFacet = GettersFacetFactory.connect(gettersContract.address, gettersContract.signer);

        const mailboxFactory = await hardhat.ethers.getContractFactory('MailboxFacet');
        const mailboxContract = await mailboxFactory.deploy();
        const mailboxFacet = MailboxFacetFactory.connect(mailboxContract.address, mailboxContract.signer);

        const allowListFactory = await hardhat.ethers.getContractFactory('AllowList');
        const allowListContract = await allowListFactory.deploy(await allowListFactory.signer.getAddress());
        allowList = AllowListFactory.connect(allowListContract.address, allowListContract.signer);

        const diamondInitFactory = await hardhat.ethers.getContractFactory('DiamondInit');
        const diamondInitContract = await diamondInitFactory.deploy();
        const diamondInit = DiamondInitFactory.connect(diamondInitContract.address, diamondInitContract.signer);

        const dummyHash = new Uint8Array(32);
        dummyHash.set([1, 0, 0, 1]);
        const dummyAddress = ethers.utils.hexlify(ethers.utils.randomBytes(20));
        const diamondInitData = diamondInit.interface.encodeFunctionData('initialize', [
            {
                verifier: dummyAddress,
                governor: await owner.getAddress(),
                admin: await owner.getAddress(),
                genesisBatchHash: ethers.constants.HashZero,
                genesisIndexRepeatedStorageChanges: 0,
                genesisBatchCommitment: ethers.constants.HashZero,
                allowList: allowList.address,
                verifierParams: {
                    recursionCircuitsSetVksHash: ethers.constants.HashZero,
                    recursionLeafLevelVkHash: ethers.constants.HashZero,
                    recursionNodeLevelVkHash: ethers.constants.HashZero
                },
                zkPorterIsAvailable: false,
                l2BootloaderBytecodeHash: dummyHash,
                l2DefaultAccountBytecodeHash: dummyHash,
                priorityTxMaxGasLimit: 10000000,
            }
        ]);

        const facetCuts = [
            facetCut(gettersFacet.address, gettersFacet.interface, Action.Add, false),
            facetCut(mailboxFacet.address, mailboxFacet.interface, Action.Add, true)
        ];

        const diamondCutData = diamondCut(facetCuts, diamondInit.address, diamondInitData);

        const diamondProxyFactory = await hardhat.ethers.getContractFactory('DiamondProxy');
        const chainId = hardhat.network.config.chainId;
        const diamondProxyContract = await diamondProxyFactory.deploy(chainId, diamondCutData);

        const l1Erc20BridgeFactory = await hardhat.ethers.getContractFactory('L1ERC20Bridge');
        l1Erc20BridgeContract = await l1Erc20BridgeFactory.deploy(
            diamondProxyContract.address,
            allowListContract.address
        );
        l1ERC20Bridge = IL1BridgeFactory.connect(l1Erc20BridgeContract.address, l1Erc20BridgeContract.signer);

        const testnetERC20TokenFactory = await hardhat.ethers.getContractFactory('TestnetERC20Token');
        testnetERC20TokenContract = await testnetERC20TokenFactory.deploy('TestToken', 'TT', 18);
        erc20TestToken = TestnetERC20TokenFactory.connect(
            testnetERC20TokenContract.address,
            testnetERC20TokenContract.signer
        );

        await erc20TestToken.mint(await randomSigner.getAddress(), ethers.utils.parseUnits('10000', 18));
        await erc20TestToken
            .connect(randomSigner)
            .approve(l1Erc20BridgeContract.address, ethers.utils.parseUnits('10000', 18));

        await (await allowList.setAccessMode(diamondProxyContract.address, AccessMode.Public)).wait();

        // Exposing the methods of IZkSync to the diamond proxy
        zksyncContract = IZkSyncFactory.connect(diamondProxyContract.address, diamondProxyContract.provider);
    });

    it(`Should not allow an un-whitelisted address to deposit`, async () => {
        const revertReason = await getCallRevertReason(
            l1ERC20Bridge
                .connect(randomSigner)
                .deposit(
                    await randomSigner.getAddress(),
                    testnetERC20TokenContract.address,
                    0,
                    0,
                    0,
                    ethers.constants.AddressZero
                )
        );
        expect(revertReason).equal(`nr`);

        await (await allowList.setAccessMode(l1Erc20BridgeContract.address, AccessMode.Public)).wait();
    });

    it(`Should not allow depositing zero amount`, async () => {
        const revertReason = await getCallRevertReason(
            l1ERC20Bridge
                .connect(randomSigner)
                .deposit(
                    await randomSigner.getAddress(),
                    testnetERC20TokenContract.address,
                    0,
                    0,
                    0,
                    ethers.constants.AddressZero
                )
        );
        expect(revertReason).equal(`2T`);
    });

    it(`Should deposit successfully`, async () => {
        const depositorAddress = await randomSigner.getAddress();
        await depositERC20(
            l1ERC20Bridge.connect(randomSigner),
            zksyncContract,
            depositorAddress,
            testnetERC20TokenContract.address,
            ethers.utils.parseUnits('800', 18),
            10000000
        );
    });

    it(`Should revert on finalizing a withdrawal with wrong message length`, async () => {
        const revertReason = await getCallRevertReason(
            l1ERC20Bridge.connect(randomSigner).finalizeWithdrawal(0, 0, 0, '0x', [])
        );
        expect(revertReason).equal(`kk`);
    });

    it(`Should revert on finalizing a withdrawal with wrong function signature`, async () => {
        const revertReason = await getCallRevertReason(
            l1ERC20Bridge.connect(randomSigner).finalizeWithdrawal(0, 0, 0, ethers.utils.randomBytes(76), [])
        );
        expect(revertReason).equal(`nt`);
    });

    it(`Should revert on finalizing a withdrawal with wrong batch number`, async () => {
        const functionSignature = `0x11a2ccc1`;
        const l1Receiver = await randomSigner.getAddress();
        const l2ToL1message = ethers.utils.hexConcat([
            functionSignature,
            l1Receiver,
            testnetERC20TokenContract.address,
            ethers.constants.HashZero
        ]);
        const revertReason = await getCallRevertReason(
            l1ERC20Bridge.connect(randomSigner).finalizeWithdrawal(10, 0, 0, l2ToL1message, [])
        );
        expect(revertReason).equal(`xx`);
    });

    it(`Should revert on finalizing a withdrawal with wrong length of proof`, async () => {
        const functionSignature = `0x11a2ccc1`;
        const l1Receiver = await randomSigner.getAddress();
        const l2ToL1message = ethers.utils.hexConcat([
            functionSignature,
            l1Receiver,
            testnetERC20TokenContract.address,
            ethers.constants.HashZero
        ]);
        const revertReason = await getCallRevertReason(
            l1ERC20Bridge.connect(randomSigner).finalizeWithdrawal(0, 0, 0, l2ToL1message, [])
        );
        expect(revertReason).equal(`xc`);
    });

    it(`Should revert on finalizing a withdrawal with wrong proof`, async () => {
        const functionSignature = `0x11a2ccc1`;
        const l1Receiver = await randomSigner.getAddress();
        const l2ToL1message = ethers.utils.hexConcat([
            functionSignature,
            l1Receiver,
            testnetERC20TokenContract.address,
            ethers.constants.HashZero
        ]);
        const revertReason = await getCallRevertReason(
            l1ERC20Bridge
                .connect(randomSigner)
                .finalizeWithdrawal(0, 0, 0, l2ToL1message, Array(9).fill(ethers.constants.HashZero))
        );
        expect(revertReason).equal(`nq`);
    });
});

async function depositERC20(
    bridge: IL1Bridge,
    zksyncContract: IZkSync,
    l2Receiver: string,
    l1Token: string,
    amount: ethers.BigNumber,
    l2GasLimit: number,
    l2RefundRecipient = ethers.constants.AddressZero
) {
    const gasPrice = await bridge.provider.getGasPrice();
    const gasPerPubdata = REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT;
    const neededValue = await zksyncContract.l2TransactionBaseCost(gasPrice, l2GasLimit, gasPerPubdata);

    await bridge.deposit(
        l2Receiver,
        l1Token,
        amount,
        l2GasLimit,
        REQUIRED_L1_TO_L2_GAS_PER_PUBDATA_LIMIT,
        l2RefundRecipient,
        {
            value: neededValue
        }
    );
}
