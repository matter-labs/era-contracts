import { expect } from 'chai';
import { ethers } from 'ethers';
import * as hardhat from 'hardhat';
import { IZkSync } from '../../typechain/IZkSync';
import { Action, diamondCut, facetCut } from '../../src.ts/diamondCut';
import {
    AllowList,
    AllowListFactory,
    DiamondInitFactory,
    GettersFacetFactory,
    MailboxFacetFactory,
    L1WethBridge,
    L1WethBridgeFactory,
    WETH9,
    WETH9Factory
} from '../../typechain';
import { AccessMode, getCallRevertReason } from './utils';
import { hashL2Bytecode } from '../../scripts/utils';

import { Interface } from 'ethers/lib/utils';
import { Address } from 'zksync-web3/build/src/types';

const DEPLOYER_SYSTEM_CONTRACT_ADDRESS = '0x0000000000000000000000000000000000008006';
const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require('../../../SystemConfig.json').REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

export async function create2DeployFromL1(
    zkSync: IZkSync,
    walletAddress: Address,
    bytecode: ethers.BytesLike,
    constructor: ethers.BytesLike,
    create2Salt: ethers.BytesLike,
    l2GasLimit: ethers.BigNumberish
) {
    const deployerSystemContracts = new Interface(hardhat.artifacts.readArtifactSync('IContractDeployer').abi);
    const bytecodeHash = hashL2Bytecode(bytecode);
    const calldata = deployerSystemContracts.encodeFunctionData('create2', [create2Salt, bytecodeHash, constructor]);
    const gasPrice = await zkSync.provider.getGasPrice();
    const expectedCost = await zkSync.l2TransactionBaseCost(gasPrice, l2GasLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);

    await zkSync.requestL2Transaction(
        DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
        0,
        calldata,
        l2GasLimit,
        REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
        [bytecode],
        walletAddress,
        { value: expectedCost, gasPrice }
    );
}

describe('WETH Bridge tests', () => {
    let owner: ethers.Signer;
    let randomSigner: ethers.Signer;
    let allowList: AllowList;
    let bridgeProxy: L1WethBridge;
    let l1Weth: WETH9;
    let functionSignature = '0x6c0960f9';

    before(async () => {
        [owner, randomSigner] = await hardhat.ethers.getSigners();

        // prepare the diamond

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
            dummyAddress,
            await owner.getAddress(),
            ethers.constants.HashZero,
            0,
            ethers.constants.HashZero,
            allowList.address,
            {
                recursionCircuitsSetVksHash: ethers.constants.HashZero,
                recursionLeafLevelVkHash: ethers.constants.HashZero,
                recursionNodeLevelVkHash: ethers.constants.HashZero
            },
            false,
            dummyHash,
            dummyHash,
            10000000
        ]);

        const facetCuts = [
            facetCut(gettersFacet.address, gettersFacet.interface, Action.Add, false),
            facetCut(mailboxFacet.address, mailboxFacet.interface, Action.Add, true)
        ];

        const diamondCutData = diamondCut(facetCuts, diamondInit.address, diamondInitData);

        const diamondProxyFactory = await hardhat.ethers.getContractFactory('DiamondProxy');
        const chainId = hardhat.network.config.chainId;
        const diamondProxyContract = await diamondProxyFactory.deploy(chainId, diamondCutData);

        await (await allowList.setAccessMode(diamondProxyContract.address, AccessMode.Public)).wait();

        l1Weth = WETH9Factory.connect(
            (await (await hardhat.ethers.getContractFactory('WETH9')).deploy()).address,
            owner
        );

        // prepare the bridge

        const bridge = await (
            await hardhat.ethers.getContractFactory('L1WethBridge')
        ).deploy(l1Weth.address, diamondProxyContract.address, allowListContract.address);

        // we don't test L2, so it is ok to give garbage factory deps and L2 address
        const garbageBytecode = '0x1111111111111111111111111111111111111111111111111111111111111111';
        const garbageAddress = '0x71C7656EC7ab88b098defB751B7401B5f6d8976F';

        const bridgeInitData = bridge.interface.encodeFunctionData('initialize', [
            [garbageBytecode, garbageBytecode],
            garbageAddress,
            await owner.getAddress(),
            ethers.constants.WeiPerEther,
            ethers.constants.WeiPerEther
        ]);
        const _bridgeProxy = await (
            await hardhat.ethers.getContractFactory('ERC1967Proxy')
        ).deploy(bridge.address, bridgeInitData, { value: ethers.constants.WeiPerEther.mul(2) });

        bridgeProxy = L1WethBridgeFactory.connect(_bridgeProxy.address, _bridgeProxy.signer);
    });

    it('Should not allow an un-whitelisted address to deposit', async () => {
        const revertReason = await getCallRevertReason(
            bridgeProxy
                .connect(randomSigner)
                .deposit(
                    await randomSigner.getAddress(),
                    ethers.constants.AddressZero,
                    0,
                    0,
                    0,
                    ethers.constants.AddressZero
                )
        );

        expect(revertReason).equal('nr');

        // This is only so the following tests don't need whitelisting
        await (await allowList.setAccessMode(bridgeProxy.address, AccessMode.Public)).wait();
    });

    it('Should not allow depositing zero WETH', async () => {
        const revertReason = await getCallRevertReason(
            bridgeProxy
                .connect(randomSigner)
                .deposit(
                    await randomSigner.getAddress(),
                    await bridgeProxy.l1WethAddress(),
                    0,
                    0,
                    0,
                    ethers.constants.AddressZero
                )
        );

        expect(revertReason).equal('Amount cannot be zero');
    });

    it(`Should deposit successfully`, async () => {
        await l1Weth.connect(randomSigner).deposit({ value: 100 });
        await (await l1Weth.connect(randomSigner).approve(bridgeProxy.address, 100)).wait();
        await bridgeProxy
            .connect(randomSigner)
            .deposit(
                await randomSigner.getAddress(),
                l1Weth.address,
                100,
                1000000,
                REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                await randomSigner.getAddress(),
                { value: ethers.constants.WeiPerEther }
            );
    });

    it('Should revert on finalizing a withdrawal with wrong message length', async () => {
        const revertReason = await getCallRevertReason(
            bridgeProxy.connect(randomSigner).finalizeWithdrawal(0, 0, 0, '0x', [])
        );
        expect(revertReason).equal('Incorrect ETH message with additional data length');
    });

    it('Should revert on finalizing a withdrawal with wrong function selector', async () => {
        const revertReason = await getCallRevertReason(
            bridgeProxy.connect(randomSigner).finalizeWithdrawal(0, 0, 0, ethers.utils.randomBytes(96), [])
        );
        expect(revertReason).equal('Incorrect ETH message function selector');
    });

    it('Should revert on finalizing a withdrawal with wrong receiver', async () => {
        const revertReason = await getCallRevertReason(
            bridgeProxy
                .connect(randomSigner)
                .finalizeWithdrawal(
                    0,
                    0,
                    0,
                    ethers.utils.hexConcat([functionSignature, ethers.utils.randomBytes(92)]),
                    []
                )
        );
        expect(revertReason).equal('Wrong L1 ETH withdraw receiver');
    });

    it('Should revert on finalizing a withdrawal with wrong L2 sender', async () => {
        const revertReason = await getCallRevertReason(
            bridgeProxy
                .connect(randomSigner)
                .finalizeWithdrawal(
                    0,
                    0,
                    0,
                    ethers.utils.hexConcat([
                        functionSignature,
                        bridgeProxy.address,
                        ethers.utils.randomBytes(32),
                        ethers.utils.randomBytes(40)
                    ]),
                    []
                )
        );
        expect(revertReason).equal('The withdrawal was not initiated by L2 bridge');
    });
});
