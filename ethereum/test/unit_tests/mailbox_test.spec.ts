import { expect } from 'chai';
import * as hardhat from 'hardhat';
import { BridgeheadFactory, BridgeheadChainFactory, AllowList, Forwarder, ForwarderFactory, MockExecutorFacet,
    MockExecutorFacetFactory, } from '../../typechain';

import * as fs from 'fs';

import {
    DEFAULT_REVERT_REASON,
    getCallRevertReason,
    AccessMode,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    requestExecute,
    requestExecuteDirect
} from './utils';
import { Wallet } from 'ethers';

import * as ethers from 'ethers';

import { Deployer } from '../../src.ts/deploy';
import { facetCut, Action } from '../../src.ts/diamondCut';


const zeroHash = '0x0000000000000000000000000000000000000000000000000000000000000000';

const L2_BOOTLOADER_BYTECODE_HASH = '0x1000100000000000000000000000000000000000000000000000000000000000';
const L2_DEFAULT_ACCOUNT_BYTECODE_HASH = '0x1001000000000000000000000000000000000000000000000000000000000000';

const testConfigPath = './test/test_config/constant';
const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: 'utf-8' }));
const addressConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/addresses.json`, { encoding: 'utf-8' }));

describe('Mailbox tests', function () {
    let allowList: AllowList;
    let bridgeheadContract: ethers.Contract;
    let bridgeheadChainContract: ethers.Contract;
    let proxyAsMockExecutor: MockExecutorFacet;
    let owner: ethers.Signer;
    let randomSigner: ethers.Signer;
    const MAX_CODE_LEN_WORDS = (1 << 16) - 1;
    const MAX_CODE_LEN_BYTES = MAX_CODE_LEN_WORDS * 32;
    let forwarder: Forwarder;
    let chainId = process.env.CHAIN_ETH_ZKSYNC_NETWORK_ID || 270;

    before(async () => {
        [owner, randomSigner] = await hardhat.ethers.getSigners();

        const deployWallet = Wallet.fromMnemonic(ethTestConfig.test_mnemonic3, "m/44'/60'/0'/0/1").connect(
            owner.provider
        );
        const ownerAddress = await deployWallet.getAddress();

        const gasPrice = await owner.provider.getGasPrice();

        const tx = {
            from: owner.getAddress(),
            to: deployWallet.address,
            value: ethers.utils.parseEther('1000'),
            nonce: owner.getTransactionCount(),
            gasLimit: 100000,
            gasPrice: gasPrice
        };

        await owner.sendTransaction(tx);

        const deployer = new Deployer({
            deployWallet,
            ownerAddress,
            verbose: false,
            addresses: addressConfig,
            bootloaderBytecodeHash: L2_BOOTLOADER_BYTECODE_HASH,
            defaultAccountBytecodeHash: L2_DEFAULT_ACCOUNT_BYTECODE_HASH
        });

        const create2Salt = ethers.utils.hexlify(ethers.utils.randomBytes(32));

        let nonce = await deployWallet.getTransactionCount();

        await deployer.deployCreate2Factory({ gasPrice, nonce });
        nonce++;

        // await deployer.deployMulticall3(create2Salt, {gasPrice, nonce});
        // nonce++;

        process.env.CONTRACTS_GENESIS_ROOT = zeroHash;
        process.env.CONTRACTS_GENESIS_ROLLUP_LEAF_INDEX = '0';
        process.env.CONTRACTS_GENESIS_BLOCK_COMMITMENT = zeroHash;
        process.env.CONTRACTS_PRIORITY_TX_MAX_GAS_LIMIT = '72000000';
        process.env.CONTRACTS_RECURSION_NODE_LEVEL_VK_HASH = zeroHash;
        process.env.CONTRACTS_RECURSION_LEAF_LEVEL_VK_HASH = zeroHash;
        process.env.CONTRACTS_RECURSION_CIRCUITS_SET_VKS_HASH = zeroHash;

        await deployer.deployAllowList(create2Salt, { gasPrice, nonce });
        await deployer.deployBridgeheadContract(create2Salt, gasPrice);
        await deployer.deployProofSystemContract(create2Salt, gasPrice);
        await deployer.deployBridgeContracts(create2Salt, gasPrice);
        await deployer.deployWethBridgeContracts(create2Salt, gasPrice);

        const verifierParams = {
            recursionNodeLevelVkHash: zeroHash,
            recursionLeafLevelVkHash: zeroHash,
            recursionCircuitsSetVksHash: zeroHash
        };

        const mockExecutorFactory = await hardhat.ethers.getContractFactory('MockExecutorFacet');
        const mockExecutorContract = await mockExecutorFactory.deploy();

        const initialDiamondCut = await deployer.initialProofSystemProxyDiamondCut();
        initialDiamondCut.facetCuts.push(facetCut(mockExecutorContract.getAddress(), mockExecutorContract.interface, Action.Add, true));

        const proofSystem = deployer.proofSystemContract(deployWallet);

        await (await proofSystem.setParams(verifierParams, initialDiamondCut)).wait();

        await deployer.registerHyperchain(create2Salt,  initialDiamondCut,gasPrice);
        chainId = deployer.chainId;

        // const validatorTx = await deployer.proofChainContract(deployWallet).setValidator(await validator.getAddress(), true);
        // await validatorTx.wait();

        allowList = deployer.l1AllowList(deployWallet);

        const allowTx = await allowList.setBatchAccessMode(
            [
                deployer.addresses.Bridgehead.BridgeheadProxy,
                deployer.addresses.Bridgehead.ChainProxy,
                deployer.addresses.ProofSystem.ProofSystemProxy,
                deployer.addresses.ProofSystem.DiamondProxy,
                deployer.addresses.Bridges.ERC20BridgeProxy,
                deployer.addresses.Bridges.WethBridgeProxy
            ],
            [
                AccessMode.Public,
                AccessMode.Public,
                AccessMode.Public,
                AccessMode.Public,
                AccessMode.Public,
                AccessMode.Public
            ]
        );
        await allowTx.wait();

        bridgeheadContract = BridgeheadFactory.connect(deployer.addresses.Bridgehead.BridgeheadProxy, deployWallet);
        bridgeheadChainContract = BridgeheadChainFactory.connect(
            deployer.addresses.Bridgehead.ChainProxy,
            deployWallet
        );

        proxyAsMockExecutor = MockExecutorFacetFactory.connect(
            deployer.addresses.ProofSystem.DiamondProxy,
            mockExecutorContract.signer
        );

        const forwarderFactory = await hardhat.ethers.getContractFactory('Forwarder');
        const forwarderContract = await forwarderFactory.deploy();
        forwarder = ForwarderFactory.connect(forwarderContract.address, forwarderContract.signer);
    });

    it('Should accept correctly formatted bytecode', async () => {
        const revertReason = await getCallRevertReason(
            requestExecute(
                chainId,
                bridgeheadContract,
                ethers.constants.AddressZero,
                ethers.BigNumber.from(0),
                '0x',
                ethers.BigNumber.from(1000000),
                [new Uint8Array(32)],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal(DEFAULT_REVERT_REASON);
    });

    it('Should not accept bytecode is not chunkable', async () => {
        const revertReason = await getCallRevertReason(
            requestExecute(
                chainId,
                bridgeheadContract,
                ethers.constants.AddressZero,
                ethers.BigNumber.from(0),
                '0x',
                ethers.BigNumber.from(100000),
                [new Uint8Array(63)],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal('pq');
    });

    it('Should not accept bytecode of even length in words', async () => {
        const revertReason = await getCallRevertReason(
            requestExecute(
                chainId,
                bridgeheadContract,
                ethers.constants.AddressZero,
                ethers.BigNumber.from(0),
                '0x',
                ethers.BigNumber.from(100000),
                [new Uint8Array(64)],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal('ps');
    });

    it('Should not accept bytecode that is too long', async () => {
        const revertReason = await getCallRevertReason(
            requestExecuteDirect(
                bridgeheadChainContract,
                ethers.constants.AddressZero,
                ethers.BigNumber.from(0),
                '0x',
                ethers.BigNumber.from(100000),
                [
                    // "+64" to keep the length in words odd and bytecode chunkable
                    new Uint8Array(MAX_CODE_LEN_BYTES + 64)
                ],
                ethers.constants.AddressZero
            )
        );

        expect(revertReason).equal('pp');
    });

    describe('Deposit and Withdrawal limit functionality', function () {
        const DEPOSIT_LIMIT = ethers.utils.parseEther('10');

        before(async () => {
            await allowList.setDepositLimit(ethers.constants.AddressZero, true, DEPOSIT_LIMIT);
        });

        it('Should not accept depositing more than the deposit limit', async () => {
            const revertReason = await getCallRevertReason(
                requestExecute(
                    chainId,
                    bridgeheadContract,
                    ethers.constants.AddressZero,
                    ethers.utils.parseEther('12'),
                    '0x',
                    ethers.BigNumber.from(100000),
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero
                )
            );

            expect(revertReason).equal(`d2`);
        });

        it('Should accept depositing less than or equal to the deposit limit', async () => {
            const gasPrice = await bridgeheadContract.provider.getGasPrice();
            const l2GasLimit = ethers.BigNumber.from(1000000);
            const l2Cost = await bridgeheadContract.l2TransactionBaseCost(
                chainId,
                gasPrice,
                l2GasLimit,
                REQUIRED_L2_GAS_PRICE_PER_PUBDATA
            );

            const revertReason = await getCallRevertReason(
                requestExecute(
                    chainId,
                    bridgeheadContract,
                    ethers.constants.AddressZero,
                    DEPOSIT_LIMIT.sub(l2Cost),
                    '0x',
                    l2GasLimit,
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero,
                    { gasPrice }
                )
            );

            expect(revertReason).equal(DEFAULT_REVERT_REASON);
        });

        it('Should not accept depositing that the accumulation is more than the deposit limit', async () => {
            const revertReason = await getCallRevertReason(
                requestExecute(
                    chainId,
                    bridgeheadContract,
                    ethers.constants.AddressZero,
                    ethers.BigNumber.from(1),
                    '0x',
                    ethers.BigNumber.from(1000000),
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero
                )
            );

            expect(revertReason).equal(`d2`);
        });
    });

    describe(`finalizeEthWithdrawal`, function () {
        const BLOCK_NUMBER = 1;
        const MESSAGE_INDEX = 0;
        const TX_NUMBER_IN_BLOCK = 0;
        const L1_RECEIVER = '0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045';
        const AMOUNT = 1;
        const MESSAGE =
            '0x6c0960f9d8dA6BF26964aF9D7eEd9e03E53415D37aA960450000000000000000000000000000000000000000000000000000000000000001';
        // MESSAGE_HASH = 0xf55ef1c502bb79468b8ffe79955af4557a068ec4894e2207010866b182445c52
        // HASHED_LOG = 0x110c937a27f7372384781fe744c2e971daa9556b1810f2edea90fb8b507f84b1
        const L2_LOGS_TREE_ROOT = '0xfa6b5a02c911a05e9dfe9e03f6dedb9cd30795bbac2aaf5bdd2632d2671a7e3d';
        const MERKLE_PROOF = [
            '0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba',
            '0xc3d03eebfd83049991ea3d3e358b6712e7aa2e2e63dc2d4b438987cec28ac8d0',
            '0xe3697c7f33c31a9b0f0aeb8542287d0d21e8c4cf82163d0c44c7a98aa11aa111',
            '0x199cc5812543ddceeddd0fc82807646a4899444240db2c0d2f20c3cceb5f51fa',
            '0xe4733f281f18ba3ea8775dd62d2fcd84011c8c938f16ea5790fd29a03bf8db89',
            '0x1798a1fd9c8fbb818c98cff190daa7cc10b6e5ac9716b4a2649f7c2ebcef2272',
            '0x66d7c5983afe44cf15ea8cf565b34c6c31ff0cb4dd744524f7842b942d08770d',
            '0xb04e5ee349086985f74b73971ce9dfe76bbed95c84906c5dffd96504e1e5396c',
            '0xac506ecb5465659b3a927143f6d724f91d8d9c4bdb2463aee111d9aa869874db'
        ];

        before(async () => {
            await proxyAsMockExecutor.saveL2LogsRootHash(BLOCK_NUMBER, L2_LOGS_TREE_ROOT);
        });

        it(`Reverts when proof is invalid`, async () => {
            let invalidProof = [...MERKLE_PROOF];
            invalidProof[0] = '0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43bb';

            const revertReason = await getCallRevertReason(
                bridgeheadChainContract.finalizeEthWithdrawal(BLOCK_NUMBER, MESSAGE_INDEX, TX_NUMBER_IN_BLOCK, MESSAGE, invalidProof)
            );
            expect(revertReason).equal(`pi`);
        });

        it(`Successful withdrawal`, async () => {
            const balanceBefore = await hardhat.ethers.provider.getBalance(L1_RECEIVER);

            await bridgeheadChainContract.finalizeEthWithdrawal(BLOCK_NUMBER, MESSAGE_INDEX, TX_NUMBER_IN_BLOCK, MESSAGE, MERKLE_PROOF);

            const balanceAfter = await hardhat.ethers.provider.getBalance(L1_RECEIVER);
            expect(balanceAfter.sub(balanceBefore)).equal(AMOUNT);
        });

        it(`Reverts when withdrawal is already finalized`, async () => {
            const revertReason = await getCallRevertReason(
                bridgeheadChainContract.finalizeEthWithdrawal(BLOCK_NUMBER, MESSAGE_INDEX, TX_NUMBER_IN_BLOCK, MESSAGE, MERKLE_PROOF)
            );
            expect(revertReason).equal(`jj`);
        });
    });

    describe(`Access mode functionality`, function () {
        before(async () => {
            // We still need to set infinite amount of allowed deposit limit in order to ensure that every fee will be accepted
            await allowList.setDepositLimit(ethers.constants.AddressZero, true, ethers.utils.parseEther('2000'));
        });

        it(`Should not allow an un-whitelisted address to call`, async () => {
            await allowList.setAccessMode(bridgeheadChainContract.address, AccessMode.Closed);

            const revertReason = await getCallRevertReason(
                requestExecute(
                    chainId,
                    bridgeheadContract.connect(randomSigner),
                    ethers.constants.AddressZero,
                    ethers.BigNumber.from(0),
                    '0x',
                    ethers.BigNumber.from(100000),
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero
                )
            );
            expect(revertReason).equal(`nr2`);
        });

        it(`Should allow the whitelisted address to call`, async () => {
            await allowList.setAccessMode(bridgeheadChainContract.address, AccessMode.SpecialAccessOnly);
            await allowList.setPermissionToCall(
                await owner.getAddress(),
                bridgeheadChainContract.address,
                `0xca0fbd7c`,
                true
            );

            const revertReason = await getCallRevertReason(
                requestExecute(
                    chainId,
                    bridgeheadContract.connect(owner),
                    ethers.constants.AddressZero,
                    ethers.BigNumber.from(0),
                    '0x',
                    ethers.BigNumber.from(1000000),
                    [new Uint8Array(32)],
                    ethers.constants.AddressZero
                )
            );
            expect(revertReason).equal(DEFAULT_REVERT_REASON);
        });
    });

    let callDirectly, callViaForwarder, callViaConstructorForwarder;

    before(async () => {
        const l2GasLimit = ethers.BigNumber.from(10000000);

        callDirectly = async (refundRecipient) => {
            return {
                transaction: await requestExecute(
                    chainId,
                    bridgeheadContract.connect(owner),
                    ethers.constants.AddressZero,
                    ethers.BigNumber.from(0),
                    '0x',
                    l2GasLimit,
                    [new Uint8Array(32)],
                    refundRecipient
                ),
                expectedSender: await owner.getAddress()
            };
        };

        const encodeRequest = (refundRecipient) =>
            bridgeheadContract.interface.encodeFunctionData('requestL2Transaction', [
                chainId,
                ethers.constants.AddressZero,
                0,
                '0x',
                l2GasLimit,
                REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
                [new Uint8Array(32)],
                refundRecipient
            ]);

        let overrides: ethers.PayableOverrides = {};
        overrides.gasPrice = await bridgeheadContract.provider.getGasPrice();
        overrides.value = await bridgeheadContract.l2TransactionBaseCost(
            chainId,
            overrides.gasPrice,
            l2GasLimit,
            REQUIRED_L2_GAS_PRICE_PER_PUBDATA
        );
        overrides.gasLimit = 10000000;

        callViaForwarder = async (refundRecipient) => {
            return {
                transaction: await forwarder.forward(
                    bridgeheadContract.address,
                    encodeRequest(refundRecipient),
                    overrides
                ),
                expectedSender: aliasAddress(forwarder.address)
            };
        };

        callViaConstructorForwarder = async (refundRecipient) => {
            const constructorForwarder = await (
                await hardhat.ethers.getContractFactory('ConstructorForwarder')
            ).deploy(bridgeheadContract.address, encodeRequest(refundRecipient), overrides);

            return {
                transaction: constructorForwarder.deployTransaction,
                expectedSender: aliasAddress(constructorForwarder.address)
            };
        };
    });

    it('Should only alias externally-owned addresses', async () => {
        const indirections = [callDirectly, callViaForwarder, callViaConstructorForwarder];
        const refundRecipients = [
            [bridgeheadContract.address, false],
            [await bridgeheadContract.signer.getAddress(), true]
        ];

        for (const sendTransaction of indirections) {
            for (const [refundRecipient, externallyOwned] of refundRecipients) {
                const result = await sendTransaction(refundRecipient);

                const [event] = (await result.transaction.wait()).logs;
                const parsedEvent = bridgeheadContract.interface.parseLog(event);
                expect(parsedEvent.name).to.equal('NewPriorityRequest');

                const canonicalTransaction = parsedEvent.args.transaction;
                expect(canonicalTransaction.from).to.equal(result.expectedSender);

                expect(canonicalTransaction.reserved[1]).to.equal(
                    externallyOwned ? refundRecipient : aliasAddress(refundRecipient)
                );
            }
        }
    });
});

function aliasAddress(address) {
    return ethers.BigNumber.from(address)
        .add('0x1111000000000000000000000000000000001111')
        .mask(20 * 8);
}
