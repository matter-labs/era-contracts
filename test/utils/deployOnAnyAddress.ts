import { BigNumber, BytesLike, Contract } from 'ethers';
import { ethers } from 'ethers';
import { Provider, types, utils } from 'zksync-web3';
import { Deployer } from '@matterlabs/hardhat-zksync-deploy';
import { hashBytecode } from 'zksync-web3/build/src/utils';
import { expect } from 'chai';
import * as hre from 'hardhat';

const DIAMOND_UPGRADE_INIT_ABI = new ethers.utils.Interface(require('./DiamondUpgradeInit.json'));
const DIAMOND_CUT_FACET_ABI = new ethers.utils.Interface(require('./DiamonCutFacet.json'));
const CONTRACT_DEPLOYER_INTERFACE = new ethers.utils.Interface(hre.artifacts.readArtifactSync('ContractDeployer').abi);
const ZKSYNC_INTERFACE = new ethers.utils.Interface(require('./IZkSync.json'));

const DEFAULT_GAS_LIMIT = 60000000;
const DIAMOND_UPGRADE_INIT_ADDRESS = '0x2CaF2C21Fa1f6d3180Eb23A0D821c0d9B4cf0553';

export interface ForceDeployment {
    // The bytecode hash to put on an address
    bytecodeHash: BytesLike;
    // The address on which to deploy the bytecodehash to
    newAddress: string;
    // The value with which to initialize a contract
    value: BigNumber;
    // The constructor calldata
    input: BytesLike;
}

export function diamondCut(facetCuts: any[], initAddress: string, initCalldata: string): any {
    return {
        facetCuts,
        initAddress,
        initCalldata
    };
}

// The same mnemonic as in the etc/test_config/eth.json
const LOCAL_GOV_MNEMONIC = 'fine music test violin matrix prize squirrel panther purchase material script deal';

export async function deployOnAnyLocalAddress(
    ethProvider: ethers.providers.Provider,
    l2Provider: Provider,
    deployments: ForceDeployment[],
    factoryDeps: BytesLike[]
): Promise<string> {
    const govWallet = ethers.Wallet.fromMnemonic(
        LOCAL_GOV_MNEMONIC,
        "m/44'/60'/0'/0/1"
    ).connect(ethProvider);

    const zkSyncContract = await l2Provider.getMainContractAddress();

    const zkSync = new ethers.Contract(
        zkSyncContract,
        ZKSYNC_INTERFACE,
        govWallet
    );
    if(!(await zkSync.getProposedDiamondCutTimestamp()).eq(0)) {
        await zkSync.cancelDiamondCutProposal();
    }

    // Encode data for the upgrade call
    const encodedParams = CONTRACT_DEPLOYER_INTERFACE.encodeFunctionData('forceDeployOnAddresses', [
        deployments
    ]);

    // Prepare the diamond cut data
    const upgradeInitData = DIAMOND_UPGRADE_INIT_ABI.encodeFunctionData('forceDeployL2Contract', [
        encodedParams,
        factoryDeps,
        DEFAULT_GAS_LIMIT
    ]);

    const upgradeParam = diamondCut([], DIAMOND_UPGRADE_INIT_ADDRESS, upgradeInitData);

    // Get transaction data of the `proposeDiamondCut`
    const proposeDiamondCut = DIAMOND_CUT_FACET_ABI.encodeFunctionData('proposeDiamondCut', [
        upgradeParam.facetCuts,
        upgradeParam.initAddress
    ]);

    // Get transaction data of the `executeDiamondCutProposal`
    const executeDiamondCutProposal = DIAMOND_CUT_FACET_ABI.encodeFunctionData(
        'executeDiamondCutProposal',
        [upgradeParam]
    );

    // Proposing the upgrade
    await (await govWallet.sendTransaction({
        to: zkSyncContract,
        data: proposeDiamondCut,
        gasLimit: BigNumber.from(10000000)
    })).wait();

    const receipt = await (await govWallet.sendTransaction({
        to: zkSyncContract,
        data: executeDiamondCutProposal,
        gasLimit: BigNumber.from(10000000)
    })).wait();

    return utils.getL2HashFromPriorityOp(receipt, zkSyncContract);
}

export async function deployContractOnAddress(
    name: string,
    address: string,
    input: BytesLike,
    deployer: Deployer,
): Promise<Contract> {
    const artifact = await deployer.loadArtifact(name);
    const bytecodeHash = hashBytecode(artifact.bytecode);

    const factoryDeps = [
        artifact.bytecode,
        ...await deployer.extractFactoryDeps(artifact)
    ];

    const deployment: ForceDeployment = {
        bytecodeHash,
        newAddress: address,
        value: BigNumber.from(0),
        input
    };

    const txHash = await deployOnAnyLocalAddress(
        deployer.ethWallet.provider,
        deployer.zkWallet.provider,
        [deployment],
        factoryDeps
    )

    const receipt = await deployer.zkWallet.provider.waitForTransaction(txHash);

    expect(receipt.status, 'Contract deployment failed').to.eq(1);
    
    return new ethers.Contract(
        address,
        artifact.abi,
        deployer.zkWallet.provider
    );
}

